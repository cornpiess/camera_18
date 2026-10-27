import Foundation
import CoreFoundation
import CoreImage
import Metal

// MARK: - Shared GPU context (red line: exactly ONE CIContext for the whole engine)
/// One Metal device + one CIContext shared by the WYSIWYG preview and the capture pipeline.
/// Never allocate a CIContext per frame or per shutter press — GPU memory leaks → Jetsam.
enum CameraEngineGPU {
  static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
  static let ciContext: CIContext = {
    if let device = metalDevice {
      return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    }
    // Simulator / exotic fallback: software-backed context.
    return CIContext(options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
  }()
  static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
}

// Shared resource lookup works in both the app and the macOS calibration executable.
private final class CameraEngineResourceAnchor: NSObject {}

// MARK: - .cube LUT Loader (Camera18_LUT_V0 pack, bundled as CameraEngineLUTs)
enum LUTLoader {
  private static let lock = NSLock()
  private static var cache: [String: (dimension: Int, data: Data)] = [:]
  /// LRU order (oldest first). A parsed 33³ cube is ~0.6 MB; the calibration library
  /// ships 57 cubes, so an uncapped cache accumulated ~35 MB of native memory forever
  /// once profiles started referencing more of the library. 8 slots hold every active
  /// profile plus quick switch neighbors with room to spare.
  private static var cacheOrder: [String] = []
  private static let cacheLimit = 8
  private static var loggedMissing: Set<String> = []

  static func load(_ rawName: String?) -> (dimension: Int, data: Data)? {
    guard let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
    lock.lock(); defer { lock.unlock() }
    if let hit = cache[name] {
      touch(name)
      return hit
    }
    guard let parsed = parseBundleLUT(named: name) else {
      // 静默跳过 LUT 会让"新相机没有效果"无从排查（典型原因：JS 列表热更新了、原生 LUT bundle 还是旧构建的）。
      // 每个名字只报一次，避免逐帧刷日志。
      if !loggedMissing.contains(name) {
        loggedMissing.insert(name)
        print("[CameraEngine] LUTLoader: missing/unparseable cube '\(name)' — LUT stage skipped (stale native bundle?)")
      }
      return nil
    }
    cache[name] = parsed
    touch(name)
    while cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
      cacheOrder.removeFirst()
      cache.removeValue(forKey: oldest)
    }
    return parsed
  }

  private static func touch(_ name: String) {
    cacheOrder.removeAll { $0 == name }
    cacheOrder.append(name)
  }

  #if CAMERA18_CALIBRATION
  // Offline executable only. The iOS app can never read an arbitrary LUT directory.
  static var calibrationDirectory: URL?
  #endif

  private static func bundleResourceURL(named name: String) -> URL? {
    let base = name.hasSuffix(".cube") ? String(name.dropLast(5)) : name
    #if CAMERA18_CALIBRATION
    if let directory = calibrationDirectory {
      let url = directory.appendingPathComponent(base).appendingPathExtension("cube")
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    #endif
    let moduleBundle = Bundle(for: CameraEngineResourceAnchor.self)
    if let url = moduleBundle.url(forResource: base, withExtension: "cube") { return url }
    // resource_bundles packaging: CameraEngineLUTs.bundle next to the module.
    if let subURL = moduleBundle.url(forResource: "CameraEngineLUTs", withExtension: "bundle"),
       let lutBundle = Bundle(url: subURL) {
      return lutBundle.url(forResource: base, withExtension: "cube")
    }
    // Static-framework packaging: resources land in the main app bundle.
    return Bundle.main.url(forResource: base, withExtension: "cube")
  }

  private static func parseBundleLUT(named name: String) -> (dimension: Int, data: Data)? {
    guard let url = bundleResourceURL(named: name),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var dimension = 0
    var values: [Float] = []
    for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("LUT_3D_SIZE") {
        dimension = Int(line.dropFirst("LUT_3D_SIZE".count).trimmingCharacters(in: .whitespaces)) ?? 0
        continue
      }
      if line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN_") || line.hasPrefix("LUT_1D_SIZE") { continue }
      let parts = line.split(whereSeparator: { $0.isWhitespace })
      guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]), r.isFinite, g.isFinite, b.isFinite else { return nil }
      // CIColorCube requires FOUR floats (RGBA, premultiplied) per entry — a 3-float RGB
      // buffer makes the whole LUT stage silently no-op (every camera's LUT dead since
      // v1; hueBandCube already did this correctly). .cube lines are RGB, alpha = 1.
      values.append(contentsOf: [r, g, b, 1])
    }
    guard dimension >= 2, dimension <= 128, values.count == dimension * dimension * dimension * 4 else { return nil }
    return (dimension, Data(bytes: values, count: values.count * MemoryLayout<Float>.size))
  }
}

// MARK: - Input Normalizer Registry (architecture v2)
/// Maps each input family's TECHNICAL deviations (gray level, white point, base
/// saturation/response, light base-tone differences) onto one shared target:
/// `camera18-neutral-v1`. STRICTLY technology-only — no HDR, no local tone mapping,
/// no sharpening, no NR, no scene recognition, no skin detection, no dynamic style.
///
/// Separation of concerns: normalizers live OUTSIDE camera-profiles.json (a device
/// compensation must never leak into a Camera's artistic identity). The registry reads
/// an optional bundled `camera-input-normalizers.json` (schema: id/source/target/
/// revision/correction) and falls back to the built-in IDENTITY v1 entries. Until real
/// calibration data exists (iPhone 18 Pro / reference charts), every entry is Identity —
/// NO invented compensation values.
enum CameraInputNormalizer {
  enum Source: String {
    case processedPhoto = "processed-photo"
    case videoFrame = "video-frame"
  }

  struct Definition {
    let id: String
    let source: Source
    let target: String
    let revision: Int
    /// Only `identity` is supported today. Future calibration adds e.g. a 33³ correction
    /// cube here; the effective-cube compiler already reserves a fusion hook for it.
    let correctionType: String
  }

  static let neutralTarget = "camera18-neutral-v1"

  private static let lock = NSLock()
  private static var cache: [Source: Definition]?
  private static var surface: [String] = []

  /// Registry lookup. Order: bundled camera-input-normalizers.json (if parseable) →
  /// built-in identity v1. Unknown/unsupported correction types fall back to identity
  /// loudly (never a half-applied correction).
  static func definition(for source: Source) -> Definition {
    lock.lock(); defer { lock.unlock() }
    if cache == nil { load() }
    return cache![source] ?? Definition(
      id: "identity-\(source.rawValue)-v1",
      source: source,
      target: neutralTarget,
      revision: 1,
      correctionType: "identity",
    )
  }

  /// Diagnostic surface: what the registry actually resolved, per input family.
  static func resolvedSummary() -> [String] {
    lock.lock(); defer { lock.unlock() }
    if cache == nil { load() }
    return surface
  }

  private static func load() {
    var definitions: [Source: Definition] = [:]
    var notes: [String] = []
    // Optional JSON override — same resource-bundle search as LUTs.
    for container in [Bundle(for: CameraEngineResourceAnchor.self), Bundle.main] {
      if let url = container.url(forResource: "camera-input-normalizers", withExtension: "json"),
         let data = try? Data(contentsOf: url),
         let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
         let entries = root["normalizers"] as? [[String: Any]] {
        for entry in entries {
          guard
            let id = entry["id"] as? String,
            let sourceRaw = entry["source"] as? String,
            let source = Source(rawValue: sourceRaw),
            let target = entry["target"] as? String,
            target == neutralTarget,
            let revision = (entry["revision"] as? NSNumber)?.intValue
          else { continue }
          let correction = (entry["correction"] as? [String: Any])?["type"] as? String ?? "identity"
          // Only identity is wired today; anything else would need cube-fusion support.
          guard correction == "identity" else {
            notes.append("\(id): correction '\(correction)' unsupported → identity")
            continue
          }
          definitions[source] = Definition(id: id, source: source, target: target, revision: revision, correctionType: correction)
          notes.append("\(id): identity (rev \(revision))")
        }
        break
      }
    }
    for source in [Source.processedPhoto, .videoFrame] where definitions[source] == nil {
      definitions[source] = Definition(
        id: "identity-\(source.rawValue)-v1",
        source: source,
        target: neutralTarget,
        revision: 1,
        correctionType: "identity",
      )
      notes.append("identity-\(source.rawValue)-v1: built-in identity (no JSON entry)")
    }
    cache = definitions
    surface = notes
  }
}

// MARK: - Unified Camera DNA Renderer (v2 — CompiledCameraProfile architecture)
/// Production renderer for preview and final output:
///   Input Normalizer (fused into the cube) → ONE effective 33³ cube → Tone stages.
/// Camera 18 does NOT redo Apple's ISP: no noise reduction, no sharpening, no unsharp
/// mask or local tone mapping. Shared vignette/highlight chroma relief; optional final-only monochrome grain;
/// no halation, no fake optical starburst or software depth blur.
///
/// COLOR PIPELINE CONTRACT (fixed; do not introduce per-path divergence):
///   Source decode (CIImage float working space) → Normalizer (fused in cube)
///   → CIColorCubeWithColorSpace with inputColorSpace = sRGB (the LUTs are calibrated
///   in sRGB — preview and final MUST keep this identical) → Tone (CI working space)
///   → Shared deharsh (highlight chroma relief, texture.deharsh) → Export sRGB. No
///   implicit per-path color-space differences, no redundant conversions. Precision:
///   Core Image processes in its float working space end to end; quantization to 8-bit
///   happens exactly once, inside the final HEIF/JPEG encode.
enum CameraDNARenderer {
  /// Bump on ANY change to cube compilation or tone application so stale cached cubes
  /// can never survive a renderer change (cache key includes this).
  static let rendererVersion = 4
  static let colorContract = "camera18-srgb-ci-v1"
  private static let hueBandNames = ["red", "orange", "yellow", "green", "cyan", "blue", "magenta"]

  /// Per-frame render state: everything expensive (cube, tone interpretation) is
  /// resolved ONCE at compile time; the frame loop consumes only this struct.
  struct CompiledCameraProfile {
    let effectiveCube: (dimension: Int, data: Data)?
    let exposureEV: Double
    let contrast: Double
    let blackPoint: Double
    let toneCurve: [CIVector]?
    /// Shared highlight chroma relief strength (texture.deharsh, 0..1).
    let deharshAmount: Double
    let grainAmount: Double
    let grainSize: Double
    let vignetteAmount: Double
    let vignetteRadius: Double
    let profileID: String
    let profileRevision: Int
    let normalizerID: String
    let normalizerRevision: Int
    let rendererVersion: Int
    /// True when NOTHING in this profile can alter pixels (identity normalizer +
    /// neutral color + neutral tone). Guaranteed filter-free by construction.
    let isIdentity: Bool
  }

  /// Unified rendering pipeline — consumes ONLY a compiled profile (no JSON per frame).
  /// Source → effective cube (normalizer + LUT + fine color) → Exposure → Contrast →
  /// Black point → Tone curve → Deharsh → Vignette → [final only: Grain]. Every stage skips itself
  /// when neutral.
  static func apply(_ compiled: CompiledCameraProfile, to source: CIImage, finalPhoto: Bool = false) -> CIImage {
    var image = source

    if let effective = compiled.effectiveCube {
      image = filter("CIColorCubeWithColorSpace", image, [
        "inputCubeDimension": effective.dimension,
        "inputCubeData": effective.data,
        "inputColorSpace": CameraEngineGPU.sRGBColorSpace,
      ])
    }

    if abs(compiled.exposureEV) > 0.001 {
      image = filter("CIExposureAdjust", image, [kCIInputEVKey: compiled.exposureEV])
    }
    if abs(compiled.contrast - 1.0) > 0.001 {
      image = filter("CIColorControls", image, [kCIInputSaturationKey: 1.0, kCIInputContrastKey: compiled.contrast, kCIInputBrightnessKey: 0.0])
    }
    if compiled.blackPoint > 0 {
      let scale = 1.0 / (1.0 - compiled.blackPoint)
      image = filter("CIColorMatrix", image, [
        "inputRVector": CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0),
        "inputBiasVector": CIVector(x: CGFloat(-compiled.blackPoint * scale), y: CGFloat(-compiled.blackPoint * scale), z: CGFloat(-compiled.blackPoint * scale), w: 0)
      ])
    }
    if let points = compiled.toneCurve {
      image = filter("CIToneCurve", image, Dictionary(uniqueKeysWithValues: points.enumerated().map { ("inputPoint\($0.offset)", $0.element) }))
    }

    // DEHARSH (shared preview/photo color stage): highlight chroma relief after the tone curve — the last
    // color-touching stage before export. Sensors clip channel-wise, and the resulting
    // saturation blowout near white is the "harsh" digital look this stage removes:
    // as luma approaches clipping the pixel is pulled toward its own luma. LUMA IS
    // UNTOUCHED (the profile's tone curve owns luminance — no highlight darkening);
    // only chroma eases, weighted by a ramp that stays near 0 through the mids and rises
    // over the highlight shoulder. Stock filters only (AGENTS.md: no custom Metal), and
    // the whole chain self-skips at amount 0 — the deharsh=0 profiles render identically.
    if compiled.deharshAmount > 0.0005 {
      let amount = compiled.deharshAmount
      let lumaWeights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
      let luma = filter("CIColorMatrix", image, [
        "inputRVector": lumaWeights, "inputGVector": lumaWeights, "inputBVector": lumaWeights,
      ])
      let mask = filter("CIToneCurve", luma, [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: 0.30, y: 0),
        "inputPoint2": CIVector(x: 0.55, y: 0.02),
        "inputPoint3": CIVector(x: 0.75, y: 0.45),
        "inputPoint4": CIVector(x: 1, y: 1),
      ])
      let desaturated = filter("CIColorControls", image, [
        kCIInputSaturationKey: CGFloat(max(0.0, 1.0 - amount * 4.0)),
        kCIInputContrastKey: CGFloat(1.0),
        kCIInputBrightnessKey: CGFloat(0.0),
      ])
      // Mask 1 = take the desaturated pixel (highlights), 0 = keep the original.
      image = filter("CIBlendWithMask", desaturated, [
        "inputBackgroundImage": image,
        "inputMaskImage": mask,
      ])
    }

    // Shared, resolution-relative corner falloff: same framing in preview and photo.
    if compiled.vignetteAmount > 0.0005 {
      let extent = source.extent
      image = filter("CIVignetteEffect", image, [
        "inputCenter": CIVector(x: extent.midX, y: extent.midY),
        "inputRadius": min(extent.width, extent.height) * CGFloat(compiled.vignetteRadius),
        "inputIntensity": compiled.vignetteAmount,
      ])
    }
    // Final only: monochrome soft-light grain around neutral gray. No subject blur
    // and no random noise shimmering in the live viewfinder. Size scales with resolution.
    if finalPhoto, compiled.grainAmount > 0.0005,
       let random = CIFilter(name: "CIRandomGenerator")?.outputImage {
      let extent = source.extent
      let scale = max(1.0, min(extent.width, extent.height) / 1600.0 * CGFloat(compiled.grainSize))
      let offset = CGAffineTransform(translationX: CGFloat.random(in: -512...512), y: CGFloat.random(in: -512...512))
      let noise = random.transformed(by: offset).transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: extent)
      let amount = CGFloat(compiled.grainAmount)
      let monochrome = CIVector(x: amount, y: 0, z: 0, w: 0)
      let grain = filter("CIColorMatrix", noise, [
        "inputRVector": monochrome, "inputGVector": monochrome, "inputBVector": monochrome,
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0.5 - amount / 2, y: 0.5 - amount / 2, z: 0.5 - amount / 2, w: 1),
      ])
      image = filter("CISoftLightBlendMode", grain, ["inputBackgroundImage": image])
    }
    return image.cropped(to: source.extent)
  }

  /// Identity contract self-check: an identity normalizer on a neutral profile must
  /// compile to cube == nil and tone == skipped (zero filters). Runs in getDiagnostics.
  static func identitySelfCheck() -> String {
    let normalizer = CameraInputNormalizer.definition(for: .processedPhoto)
    let compiled = compile([:], normalizer: normalizer)
    if compiled.effectiveCube != nil { return "FAIL: identity compile produced a color cube" }
    if !compiled.isIdentity { return "FAIL: identity compile is not flagged identity" }
    return "pass"
  }

  private static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

  // ── Compile + cache (v2) ───────────────────────────────────────────────────────
  // The effective cube fuses, per profile: Input Normalizer → base LUT × lutIntensity →
  // temperature/tint → saturation → 7-band HSL fine trim — into ONE 33³ cube. The cache
  // key is the FULL identity: profile.id + profile.revision + normalizer.id +
  // normalizer.revision + rendererVersion, so any algorithm/normalizer change invalidates
  // stale cubes by construction.
  private struct CompiledKey: Hashable {
    let profileID: String
    let profileRevision: Int
    let normalizerID: String
    let normalizerRevision: Int
    let rendererVersion: Int
  }
  private static var compiledCache: [CompiledKey: CompiledCameraProfile] = [:]
  private static var profileRevisions: [String: Int] = [:]
  /// Last-seen color payload fingerprint per profile id: lets repeated setProfile calls
  /// with an UNCHANGED profile keep the current revision (no rebuild, no cache growth).
  private static var profileColorFingerprints: [String: Int] = [:]
  private static let cubeLock = NSLock()

  /// Bump the revision ONLY when a profile's RENDERED payload actually changed. setProfile
  /// runs on every RN prop application AND through applyProfile — historically twice per
  /// aperture-drag tick, which rebuilt this 33³ cube on the render queue each time and
  /// leaked one ~0.5 MB cache entry per rebuild. Tone is compiled once with the cube and
  /// read from the CompiledCameraProfile afterwards — never from JSON per frame.
  static func invalidateCompiledProfile(_ profile: [String: Any]) {
    guard let id = profile["id"] as? String else { return }
    // Color + tone + texture: the compiled profile carries ALL three (cube, tone stages,
    // shared deharsh) — a texture-only or tone-only edit (ProfileConfigModal imports)
    // must bump the revision too, or the cache serves the stale compiled stages.
    let fingerprint = colorFingerprint([
      "color": profile["color"] ?? NSNull(),
      "tone": profile["tone"] ?? NSNull(),
      "texture": profile["texture"] ?? NSNull(),
    ])
    cubeLock.lock(); defer { cubeLock.unlock() }
    if let seen = profileColorFingerprints[id], seen == fingerprint { return }
    profileColorFingerprints[id] = fingerprint
    profileRevisions[id, default: 0] += 1
  }

  private static func colorFingerprint(_ color: Any?) -> Int {
    guard let color else { return 0 }
    var hasher = Hasher()
    if let data = try? JSONSerialization.data(withJSONObject: color, options: [.sortedKeys]) {
      hasher.combine(data)
    } else {
      // Unserializable payload: never match a previous fingerprint (forces a rebuild).
      hasher.combine(UUID().uuidString)
    }
    return hasher.finalize()
  }

  /// Compiles (or cache-hits) the per-frame render state for one profile + normalizer.
  static func compile(_ profile: [String: Any], normalizer: CameraInputNormalizer.Definition) -> CompiledCameraProfile {
    let id = (profile["id"] as? String) ?? "anonymous"
    let tone = dictionary(profile["tone"])
    let color = dictionary(profile["color"])

    // Tone interpretation happens HERE, once — never per frame.
    let exposureEV = number(tone, "exposure", 0, -5...5)
    let contrast = number(tone, "contrast", 1, 0...4)
    let blackPoint = number(tone, "blackPoint", 0, 0...0.95)
    let rawCurve = toneCurve(tone["curve"])
    let curve = (rawCurve != nil && !isIdentityToneCurve(rawCurve!)) ? rawCurve : nil
    let toneIsNeutral = abs(exposureEV) <= 0.001 && abs(contrast - 1.0) <= 0.001 && blackPoint <= 0 && curve == nil
    // Shared color-stage strength (texture.deharsh, 0..1). Absent = 0 = skipped.
    let deharshAmount = number(dictionary(profile["texture"]), "deharsh", 0, 0...1)
    let texture = dictionary(profile["texture"])
    let grain = dictionary(texture["grain"]), vignette = dictionary(texture["vignette"])
    let grainAmount = number(grain, "amount", 0, 0...0.2)
    let vignetteAmount = number(vignette, "amount", 0, 0...0.5)

    let revision: Int = {
      cubeLock.lock(); defer { cubeLock.unlock() }
      return profileRevisions[id] ?? 0
    }()

    let key = CompiledKey(
      profileID: id,
      profileRevision: revision,
      normalizerID: normalizer.id,
      normalizerRevision: normalizer.revision,
      rendererVersion: rendererVersion,
    )
    cubeLock.lock()
    if let hit = compiledCache[key] { cubeLock.unlock(); return hit }
    cubeLock.unlock()

    // Color stages (including split tone) are fused into ONE cube. No-LUT profiles
    // start from an identity base; completely neutral profiles stay filter-free.
    let effectiveCube: (dimension: Int, data: Data)?
    if let lutName = color["lut"] as? String, let baseLUT = LUTLoader.load(lutName) {
      effectiveCube = buildEffectiveCube(profile: profile, base: baseLUT, normalizer: normalizer)
    } else {
      // No-LUT profiles use the same color chain, including global adjustments.
      let colorIsNeutral = number(color, "saturation", 1, 0...4) == 1
        && number(color, "temperature", 0, -4500...5500) == 0
        && number(color, "tint", 0, -200...200) == 0
        && !hueBandNames.contains(where: { name in
          let band = dictionary(dictionary(color["hueBands"])[name])
          return abs(number(band, "hue", 0, -180...180)) > 0.0001
            || abs(number(band, "saturation", 1, 0...4) - 1) > 0.0001
            || abs(number(band, "luminance", 1, 0...4) - 1) > 0.0001
        })
        && splitToneOffsets(color).allSatisfy { abs($0) < 0.00001 }
      if colorIsNeutral {
        effectiveCube = nil
      } else {
        let dimension = 33
        var identity = [Float]()
        identity.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension { for green in 0..<dimension { for red in 0..<dimension {
          identity.append(contentsOf: [Float(red) / 32, Float(green) / 32, Float(blue) / 32, 1])
        } } }
        effectiveCube = buildEffectiveCube(profile: profile, base: (dimension, dataFromFloats(identity)), normalizer: normalizer)
      }
    }

    let compiled = CompiledCameraProfile(
      effectiveCube: effectiveCube,
      exposureEV: exposureEV,
      contrast: contrast,
      blackPoint: blackPoint,
      toneCurve: curve,
      deharshAmount: deharshAmount,
      grainAmount: grainAmount,
      grainSize: number(grain, "size", 1, 0.5...3),
      vignetteAmount: vignetteAmount,
      vignetteRadius: number(vignette, "radius", 0.75, 0.3...1.5),
      profileID: id,
      profileRevision: revision,
      normalizerID: normalizer.id,
      normalizerRevision: normalizer.revision,
      rendererVersion: rendererVersion,
      isIdentity: effectiveCube == nil && toneIsNeutral && deharshAmount <= 0.0005 && grainAmount <= 0.0005 && vignetteAmount <= 0.0005
    )

    cubeLock.lock()
    compiledCache[key] = compiled
    // Drop superseded entries: per profile keep only the newest revision (both live
    // normalizer variants of it — preview + final); older revisions are unreachable.
    compiledCache = compiledCache.filter { $0.key.profileID != id || $0.key.profileRevision == revision }
    cubeLock.unlock()
    return compiled
  }

  private static func buildEffectiveCube(profile: [String: Any], base: (dimension: Int, data: Data), normalizer: CameraInputNormalizer.Definition) -> (dimension: Int, data: Data) {
    let color = dictionary(profile["color"])
    let dim = base.dimension
    var values = floatArray(base.data)
    let count = dim * dim * dim

    // 0. INPUT NORMALIZER fusion hook (architecture v2). The normalizer maps the input
    // family's technical deviations onto camera18-neutral-v1 BEFORE the LUT — fused
    // into this same cube (per grid entry: output = profileChain(normalizer(coord))).
    // Identity correction (the only wired type today) is a mathematical no-op here:
    // the compiled cube must be bit-identical to the pre-normalizer architecture, so
    // the six cameras' current visuals are untouched.
    assert(normalizer.correctionType == "identity", "non-identity normalizer corrections need cube-fusion support first")

    // 1. lutIntensity: blend each entry toward its own grid coordinate (the identity
    // mapping), i.e. out = intensity·LUT(coord) + (1−intensity)·coord — the cube form of
    // the pre-refactor alpha-fade blend over the un-luted image, which is what the
    // calibrated 0.5–0.6 values were tuned against.
    //
    // BUILD 42 CRASH ROOT CAUSE: the previous loop advanced ONE index by 4+4+4+1 per
    // entry (values[i], then values[i+4], then values[i+8] — not R/G/B of the entry),
    // both scraping the wrong channels and running off the end of the array: with a
    // 33³ cube (143,748 floats) the last group read index 143,749 → Swift
    // index-out-of-range trap → the app died on the FIRST preview frame on device,
    // exactly "crash right after granting camera permission". Fixed indices per entry
    // (o, o+1, o+2; alpha untouched) are mandatory in this loop.
    let intensity = Float(number(color, "lutIntensity", 1, 0...1))
    if intensity < 0.999 {
      let denominator = Float(dim - 1)
      // CIColorCube/.cube order: RED varies fastest, then green, then blue.
      for index in 0..<count {
        let o = index * 4
        values[o] = intensity * values[o]
          + (1 - intensity) * Float(index % dim) / denominator
        values[o + 1] = intensity * values[o + 1]
          + (1 - intensity) * Float((index / dim) % dim) / denominator
        values[o + 2] = intensity * values[o + 2]
          + (1 - intensity) * Float(index / (dim * dim)) / denominator
      }
    }

    // 2. Temperature/tint (offset from 6500 K neutral, like the old CITemperatureAndTint).
    let kelvin = min(12_000.0, max(2_000.0, 6_500.0 + number(color, "temperature", 0, -4_500...5_500)))
    let tint = number(color, "tint", 0, -200...200)
    let tempGain: (Double, Double, Double) = {
      // Approximate CITemperatureAndTint's neutral→target ramp by RGB gain ratios.
      let t = kelvin / 6_500.0
      return (min(2.0, pow(t, 0.22)), 1.0, min(2.0, pow(1.0 / t, 0.22)))
    }()
    let tintGainG = 1.0 - tint * 0.0006
    let tintGainRB = 1.0 + tint * 0.0003
    let needsTemp = abs(kelvin - 6_500.0) > 0.5 || abs(tint) > 0.01
    // 3. Saturation (luma-preserving, same Rec.709 weights as CIColorControls).
    let sat = Float(number(color, "saturation", 1, 0...4))
    // One production HSL definition, also used by no-LUT profiles.
    let bandCenters: [Double] = [0, 30, 57, 117, 182, 230, 302]
    let adjustments = zip(hueBandNames, bandCenters).map { name, center -> (Double, Double, Double, Double) in
      let band = dictionary(dictionary(color["hueBands"])[name])
      return (center, number(band, "hue", 0, -180...180), number(band, "saturation", 1, 0...4), number(band, "luminance", 1, 0...4))
    }
    let needsHSL = adjustments.contains { abs($0.1) > 0.0001 || abs($0.2 - 1) > 0.0001 || abs($0.3 - 1) > 0.0001 }
    let split = splitToneOffsets(color)
    let needsSplit = split.contains { abs($0) > 0.00001 }

    if needsTemp || sat != 1.0 || needsHSL || needsSplit {
      for index in 0..<count {
        let o = index * 4
        var r = Double(values[o]), g = Double(values[o + 1]), b = Double(values[o + 2])
        if needsTemp {
          r *= tempGain.0; b *= tempGain.2
          g *= tintGainG; r *= tintGainRB; b *= tintGainRB
        }
        if sat != 1.0 {
          let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
          r = luma + (r - luma) * Double(sat)
          g = luma + (g - luma) * Double(sat)
          b = luma + (b - luma) * Double(sat)
        }
        if needsHSL {
          var hsl = rgbToHSL(min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
          var hueShift = 0.0, saturation = 1.0, luminance = 1.0, weightSum = 0.0
          for item in adjustments {
            let distance = circularDistance(hsl.h, item.0)
            let weight = max(0.0, 1.0 - (distance / 42.0))
            if weight > 0 {
              let smooth = weight * weight * (3.0 - 2.0 * weight)
              hueShift += item.1 * smooth
              saturation += (item.2 - 1.0) * smooth
              luminance += (item.3 - 1.0) * smooth
              weightSum += smooth
            }
          }
          if weightSum > 0 {
            hsl.h = fmod(hsl.h + (hueShift / weightSum) + 360.0, 360.0)
            hsl.s = min(1.0, max(0.0, hsl.s * max(0.0, saturation)))
            hsl.l = min(1.0, max(0.0, hsl.l * max(0.0, luminance)))
          }
          let rgb = hslToRGB(hsl.h, hsl.s, hsl.l)
          r = rgb.0; g = rgb.1; b = rgb.2
        }
        if needsSplit {
          let luma = min(1.0, max(0.0, 0.2126 * r + 0.7152 * g + 0.0722 * b))
          // Smooth masks leave black/white neutral and protect warm skin colors.
          let hsl = rgbToHSL(min(1, max(0, r)), min(1, max(0, g)), min(1, max(0, b)))
          let skin = max(0.0, 1.0 - circularDistance(hsl.h, 30) / 35) * min(1.0, hsl.s * 3)
          let protection = 1.0 - 0.65 * skin
          let shadow = (1 - smoothStep(0.08, 0.55, luma)) * smoothStep(0, 0.08, luma) * protection
          let highlight = smoothStep(0.45, 0.95, luma) * (1 - smoothStep(0.95, 1, luma)) * protection
          let dr = split[0] * shadow + split[3] * highlight
          let dg = split[1] * shadow + split[4] * highlight
          let db = split[2] * shadow + split[5] * highlight
          let biasLuma = 0.2126 * dr + 0.7152 * dg + 0.0722 * db
          r += dr - biasLuma; g += dg - biasLuma; b += db - biasLuma
        }
        values[o] = Float(min(1.0, max(0.0, r)))
        values[o + 1] = Float(min(1.0, max(0.0, g)))
        values[o + 2] = Float(min(1.0, max(0.0, b)))
      }
    }
    return (dim, dataFromFloats(values))
  }

  /// Data ↔ [Float] conversions that compile on every Swift 5/6 toolchain (the naive
  /// `[Float](data)` and `Data(buffer: [Float]` forms do not).
  private static func floatArray(_ data: Data) -> [Float] {
    var result = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
    result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    return result
  }
  private static func dataFromFloats(_ floats: [Float]) -> Data {
    var copy = floats
    return copy.withUnsafeBytes { Data($0) }
  }

  private static func splitToneOffsets(_ color: [String: Any]) -> [Double] {
    let split = dictionary(color["splitTone"])
    return ["shadows", "highlights"].flatMap { key -> [Double] in
      guard let values = split[key] as? [NSNumber], values.count == 3 else { return [0, 0, 0] }
      return values.map { value in
        let offset = value.doubleValue
        return offset.isFinite ? min(0.12, max(-0.12, offset)) : 0
      }
    }
  }

  private static func smoothStep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = min(1.0, max(0.0, (value - low) / (high - low)))
    return t * t * (3 - 2 * t)
  }

  private static func number(_ values: [String: Any], _ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
    guard let boxed = values[key] as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID() else { return fallback }
    let value = boxed.doubleValue
    guard value.isFinite else { return fallback }
    return min(range.upperBound, max(range.lowerBound, value))
  }

  private static func toneCurve(_ value: Any?) -> [CIVector]? {
    guard let values = value as? [Any], values.count == 5 else { return nil }
    var result: [CIVector] = []
    for value in values {
      guard let pair = value as? [Any], pair.count == 2,
            let x = (pair[0] as? NSNumber)?.doubleValue, let y = (pair[1] as? NSNumber)?.doubleValue,
            x.isFinite, y.isFinite else { return nil }
      result.append(CIVector(x: CGFloat(min(1, max(0, x))), y: CGFloat(min(1, max(0, y)))))
    }
    return result
  }

  /// NEUTRAL PASSTHROUGH: an identity curve (y == x everywhere) must not run through
  /// CIToneCurve (a needless filter pass on a full-res image).
  private static func isIdentityToneCurve(_ points: [CIVector]) -> Bool {
    points.allSatisfy { abs($0.x - $0.y) < 0.0001 }
  }

  private static func circularDistance(_ a: Double, _ b: Double) -> Double {
    let diff = fmod(abs(a - b), 360.0)
    return diff > 180.0 ? 360.0 - diff : diff
  }

  private static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
    let maxV = max(r, max(g, b)), minV = min(r, min(g, b)), delta = maxV - minV
    var h = 0.0, s = 0.0, l = (maxV + minV) / 2.0
    if delta > 0.00001 {
      s = l > 0.5 ? delta / (2.0 - maxV - minV) : delta / (maxV + minV)
      if maxV == r { h = ((g - b) / delta) + (g < b ? 6.0 : 0.0) }
      else if maxV == g { h = ((b - r) / delta) + 2.0 }
      else { h = ((r - g) / delta) + 4.0 }
      h *= 60.0
    }
    return (h, s, l)
  }

  private static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    guard s > 0.00001 else { return (l, l, l) }
    let q = l < 0.5 ? l * (1.0 + s) : l + s - (l * s)
    let p = (2.0 * l) - q
    let hk = h / 360.0
    return (hueToRGB(p, q, hk + (1.0 / 3.0)), hueToRGB(p, q, hk), hueToRGB(p, q, hk - (1.0 / 3.0)))
  }

  private static func hueToRGB(_ p: Double, _ q: Double, _ t: Double) -> Double {
    var tc = t
    if tc < 0 { tc += 1.0 }
    if tc > 1 { tc -= 1.0 }
    if tc < 1.0 / 6.0 { return p + ((q - p) * 6.0 * tc) }
    if tc < 1.0 / 2.0 { return q }
    if tc < 2.0 / 3.0 { return p + ((q - p) * ((2.0 / 3.0) - tc) * 6.0) }
    return p
  }

  private static func filter(_ name: String, _ input: CIImage, _ parameters: [String: Any]) -> CIImage {
    guard let filter = CIFilter(name: name) else { return input }
    filter.setValue(input, forKey: kCIInputImageKey)
    let keys = Set(filter.inputKeys)
    for (key, value) in parameters where keys.contains(key) {
      filter.setValue(value, forKey: key)
    }
    return filter.outputImage ?? input
  }
}
