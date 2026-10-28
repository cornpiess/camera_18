// Compiled WITH CameraProfileRenderer.swift: no copied filter implementation.
// macOS only; no camera, signing, PhotoKit, Expo or network access.
import Foundation
import CoreImage
import CoreFoundation
import ImageIO
import Darwin

enum CalibrationError: Error, CustomStringConvertible {
  case invalid(String)
  var description: String { switch self { case .invalid(let message): return message } }
}

func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw CalibrationError.invalid(message) }
}

func readJSON(_ path: String) throws -> Any {
  try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
}

func selectedProfile(_ path: String, _ id: String) throws -> [String: Any] {
  let value = try readJSON(path)
  let root = value as? [String: Any] ?? [:]
  let profiles = root["profiles"] as? [[String: Any]] ?? [root]
  guard let profile = profiles.first(where: { $0["id"] as? String == id }) else {
    throw CalibrationError.invalid("Unknown profile: \(id)")
  }
  if let name = (profile["color"] as? [String: Any])?["lut"] as? String {
    try require(LUTLoader.load(name) != nil, "Missing or invalid LUT: \(name)")
  }
  return profile
}

func compiled(_ profile: [String: Any], preview: Bool) -> CameraDNARenderer.CompiledCameraProfile {
  CameraDNARenderer.invalidateCompiledProfile(profile)
  return CameraDNARenderer.compile(profile, normalizer: CameraInputNormalizer.definition(for: preview ? .videoFrame : .processedPhoto))
}

func readProbes(_ path: String) throws -> [[Double]] {
  guard let rows = try readJSON(path) as? [[NSNumber]], !rows.isEmpty else {
    throw CalibrationError.invalid("Probes must be a nonempty array of RGB triples")
  }
  return try rows.map { row in
    try require(row.count == 3 && row.allSatisfy { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (0...1).contains($0.doubleValue) }, "Probes must be finite numeric RGB triples in 0...1")
    return row.map { $0.doubleValue }
  }
}

func renderProbes(_ rows: [[Double]], profile: [String: Any], preview: Bool) -> [[Double]] {
  if profile["passthrough"] as? Bool == true { return rows }
  let pixels: [Float] = rows.flatMap { [Float($0[0]), Float($0[1]), Float($0[2]), Float(1)] }
  let data = pixels.withUnsafeBytes { Data($0) }
  let source = CIImage(bitmapData: data, bytesPerRow: rows.count * 16,
    size: CGSize(width: CGFloat(rows.count), height: 1), format: .RGBAf, colorSpace: CameraEngineGPU.sRGBColorSpace)
  let image = CameraDNARenderer.apply(compiled(profile, preview: preview), to: source, finalPhoto: !preview)
  var output = [Float](repeating: 0, count: pixels.count)
  output.withUnsafeMutableBytes { buffer in
    CameraEngineGPU.ciContext.render(image, toBitmap: buffer.baseAddress!, rowBytes: rows.count * 16,
      bounds: source.extent, format: .RGBAf, colorSpace: CameraEngineGPU.sRGBColorSpace)
  }
  return rows.indices.map { index in
    let o = index * 4
    return [Double(output[o]), Double(output[o + 1]), Double(output[o + 2])]
  }
}

func writeJSON(_ value: [String: Any], path: String?) throws {
  let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
  if let path { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
  else { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8)) }
}

func selfTest() throws {
  try require(CameraDNARenderer.identitySelfCheck() == "pass", "Identity compile failed")
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  LUTLoader.calibrationDirectory = directory
  var cube = "LUT_3D_SIZE 33\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n"
  for b in 0..<33 { for g in 0..<33 { for r in 0..<33 {
    cube += "\(Double(r)/32) \(Double(g)/32) \(Double(b)/32)\n"
  } } }
  try cube.write(to: directory.appendingPathComponent("calibration-identity.cube"), atomically: true, encoding: .utf8)
  let input = (0...32).map { [Double($0)/32, Double($0)/32, Double($0)/32] }
    + [[0.8, 0.3, 0.1], [0.1, 0.5, 0.9], [0.2, 0.7, 0.3], [0.95, 0.8, 0.65], [0.95, 0.95, 0.5]]
  let profile: [String: Any] = ["id": "identity-probe", "color": ["lut": "calibration-identity"]]
  let identity = renderProbes(input, profile: profile, preview: false)
  let identityError = zip(input, identity).flatMap { pair in zip(pair.0, pair.1).map { abs($0 - $1) } }.max() ?? 1
  try require(identityError < 0.003, "LUT input/output transfer-function mismatch: identity RGB error=\(identityError)")
  let relief: [String: Any] = ["id": "relief-probe", "texture": ["deharsh": 0.1]]
  let preview = renderProbes(input, profile: relief, preview: true)
  let photo = renderProbes(input, profile: relief, preview: false)
  let sharedError = zip(preview, photo).flatMap { pair in zip(pair.0, pair.1).map { abs($0 - $1) } }.max() ?? 1
  try require(sharedError < 0.0001, "Preview/photo color stages diverge")
  let relievedDifference = zip(input, photo).flatMap { pair in zip(pair.0, pair.1).map { abs($0 - $1) } }.max() ?? 0
  try require(relievedDifference > 0.0001, "Deharsh stage did not affect any highlight probes")
  let unified: [String: Any] = ["id": "v2-identity", "recipe": ["colorContract": CameraDNARenderer.colorContract],
    "color": ["lut": "calibration-identity"]]
  let unifiedIdentity = renderProbes(input, profile: unified, preview: false)
  let unifiedIdentityError = zip(input, unifiedIdentity).flatMap { pair in zip(pair.0, pair.1).map { abs($0 - $1) } }.max() ?? 1
  try require(unifiedIdentityError < 0.003, "v2 identity transfer mismatch")
  var colorOnly = unified
  colorOnly["id"] = "v2-color-only"
  colorOnly["color"] = ["lut": "calibration-identity", "saturation": 1.4, "temperature": 800]
  let colorCompiled = compiled(colorOnly, preview: false)
  guard let colorData = colorCompiled.effectiveCube else { throw CalibrationError.invalid("Missing color-only cube") }
  var cubeValues = [Float](repeating: 0, count: colorData.data.count / MemoryLayout<Float>.size)
  cubeValues.withUnsafeMutableBytes { colorData.data.copyBytes(to: $0) }
  var lumaError = 0.0
  let dimension = colorData.dimension
  for index in 0..<(dimension * dimension * dimension) {
    let o = index * 4
    let expected = (0.2126 * Double(index % dimension) + 0.7152 * Double((index / dimension) % dimension)
      + 0.0722 * Double(index / (dimension * dimension))) / Double(dimension - 1)
    let actual = 0.2126 * Double(cubeValues[o]) + 0.7152 * Double(cubeValues[o + 1]) + 0.0722 * Double(cubeValues[o + 2])
    try require((0...1).contains(cubeValues[o]) && (0...1).contains(cubeValues[o + 1]) && (0...1).contains(cubeValues[o + 2]), "v2 cube escaped gamut")
    lumaError = max(lumaError, abs(expected - actual))
  }
  try require(lumaError < 0.000001, "Color cube unexpectedly changed encoded luma")
  var protected = colorOnly
  protected["id"] = "v2-protected"
  protected["adaptive"] = ["highlightProtection": 0.5, "shadowChromaProtection": 0.2, "skinProtection": 0.2]
  protected["tone"] = ["curve": [[0,0],[0.25,0.25],[0.5,0.5],[0.75,0.75],[1,0.98]]]
  let previewProtected = renderProbes(input, profile: protected, preview: true)
  let photoProtected = renderProbes(input, profile: protected, preview: false)
  let protectedError = zip(previewProtected, photoProtected).flatMap { pair in zip(pair.0,pair.1).map { abs($0 - $1) } }.max() ?? 1
  try require(protectedError < 0.0001, "v2 preview/photo diverged")
  let dark = CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
  let bright = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: dark.extent)
  let darkScene = CameraSceneContext.analyze(dark), brightScene = CameraSceneContext.analyze(bright)
  try require(darkScene.sampled && darkScene.shadows > brightScene.shadows && brightScene.highlights > darkScene.highlights,
    "Scene analysis failed dark/bright separation")
  let bounded = brightScene.bounded(by: darkScene)
  try require(abs(bounded.highlights - darkScene.highlights) <= 0.150001 && abs(bounded.shadows - darkScene.shadows) <= 0.150001,
    "Final scene exceeded the exposure's frozen bounds")
  var detail = unified
  detail["id"] = "v2-detail"
  detail["texture"] = ["detail": ["edgeSoftness": 0.35, "radius": 1.5]]
  let patch = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 512, y: 0, width: 512, height: 1024))
  let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1024, height: 1024))
  let edge = patch.composited(over: black)
  let detailed = CameraDNARenderer.apply(compiled(detail, preview: false), to: edge, finalPhoto: true)
  try require(detailed.extent == edge.extent, "Detail stage expanded extent")
  func pixels(_ image: CIImage, area: CGRect = CGRect(x: 508, y: 508, width: 8, height: 8)) -> [Float] {
    var result = [Float](repeating: 0, count: 8 * 8 * 4)
    result.withUnsafeMutableBytes { buffer in
      CameraEngineGPU.ciContext.render(image, toBitmap: buffer.baseAddress!, rowBytes: 8 * 16,
        bounds: area, format: .RGBAf, colorSpace: CameraEngineGPU.sRGBColorSpace)
    }
    return result
  }
  let originalPixels = pixels(edge), softenedPixels = pixels(detailed)
  try require(softenedPixels.allSatisfy { $0.isFinite && $0 >= -0.001 && $0 <= 1.001 }, "Detail produced invalid pixels")
  let edgeDifference = zip(originalPixels, softenedPixels).map { abs($0 - $1) }.max() ?? 0
  try require(edgeDifference > 0.00001 && edgeDifference < 0.25, "Fine edge stage is ineffective or excessive")
  for area in [CGRect(x: 100, y: 100, width: 8, height: 8), CGRect(x: 800, y: 100, width: 8, height: 8)] {
    let flatError = zip(pixels(edge, area: area), pixels(detailed, area: area)).map { abs($0 - $1) }.max() ?? 1
    try require(flatError < 0.0001, "Detail stage changed a flat region")
  }
  var sameIDLegacy = colorOnly
  sameIDLegacy["recipe"] = ["colorContract": CameraDNARenderer.legacyColorContract]
  try require(!compiled(sameIDLegacy, preview: false).unified && compiled(colorOnly, preview: false).unified,
    "Changing only the recipe contract reused a stale compiled graph")
  for sample in 1...100 { CameraRenderTimings.record(.photoProcessing, milliseconds: Double(sample)) }
  let timings = CameraRenderTimings.snapshot()["photoProcessing"] as? [String: Any] ?? [:]
  try require(timings["samples"] as? Int == 64, "Timing diagnostics grew past their bound")
  try writeJSON(["rendererVersion": CameraDNARenderer.rendererVersion,
    "colorContract": CameraDNARenderer.colorContract, "identityMaxRGBError": identityError,
    "sharedColorMaxRGBError": sharedError, "v2IdentityMaxRGBError": unifiedIdentityError,
    "v2CubeEncodedLumaMaxError": lumaError, "v2PreviewPhotoMaxError": protectedError, "edgeMaxDifference": edgeDifference, "status": "pass"], path: nil)
}

@main enum CameraCalibrationCLI {
  static func main() {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      if args == ["self-test"] { try selfTest(); return }
      try require(args.count == 7 && ["render", "render-raw", "probes"].contains(args[0]),
        "Usage: native-calibration self-test | (render|render-raw|probes) <profiles.json> <id> <lut-dir> <input> <output> <preview|final>")
      try require(["preview", "final"].contains(args[6]), "Mode must be preview or final")
      LUTLoader.calibrationDirectory = URL(fileURLWithPath: args[3])
      let profile = try selectedProfile(args[1], args[2])
      let preview = args[6] == "preview"
      if args[0] == "probes" {
        // Probe responses measure color only; spatial stages cannot be measured on a strip.
        var colorProfile = profile
        var texture = profile["texture"] as? [String: Any] ?? [:]
        texture["grain"] = ["amount": 0, "size": 1]
        texture["vignette"] = ["amount": 0, "radius": 0.75]
        texture.removeValue(forKey: "detail")
        colorProfile.removeValue(forKey: "adaptive")
        colorProfile["texture"] = texture
        let input = try readProbes(args[4])
        try writeJSON(["rendererVersion": CameraDNARenderer.rendererVersion,
          "colorContract": (profile["recipe"] as? [String: Any])?["colorContract"] ?? CameraDNARenderer.legacyColorContract, "mode": args[6],
          "profileId": profile["id"] ?? "unknown",
          "recipeVersion": (profile["recipe"] as? [String: Any])?["version"] ?? "legacy/unversioned",
          "lut": (profile["color"] as? [String: Any])?["lut"] ?? NSNull(),
          "input": input, "output": renderProbes(input, profile: colorProfile, preview: preview)], path: args[5])
        return
      }
      let inputURL = URL(fileURLWithPath: args[4]), outputURL = URL(fileURLWithPath: args[5])
      try require(inputURL.standardizedFileURL != outputURL.standardizedFileURL, "Output must differ from input")
      if profile["passthrough"] as? Bool == true {
        try require(inputURL.pathExtension.lowercased() == outputURL.pathExtension.lowercased(), "ORIG preserves bytes: keep the original extension")
        try Data(contentsOf: inputURL).write(to: outputURL, options: .atomic)
        return
      }
      try require(outputURL.pathExtension.lowercased() == "png", "Reference renders must be lossless PNG")
      let start = Date()
      let source: CIImage
      var sourceInfo: [String: Any] = ["kind": "processed"]
      if args[0] == "render-raw" {
        // Engineering comparison only. Display-referred RAW decoding feeds the SAME
        // style engine; no RAW capture toggle or per-brand decoder enters the app.
        guard #available(macOS 12.0, *) else { throw CalibrationError.invalid("RAW decoding requires macOS 12+") }
        guard let raw = CIRAWFilter(imageURL: inputURL) else { throw CalibrationError.invalid("RAW decoder unavailable") }
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0.15 }
        if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0.2 }
        raw.extendedDynamicRangeAmount = 0
        guard let image = raw.outputImage else { throw CalibrationError.invalid("RAW decoding failed") }
        source = image
        sourceInfo = ["kind": "raw", "decoder": String(describing: raw.decoderVersion),
          "sharpnessSupported": raw.isSharpnessSupported, "localToneMapSupported": raw.isLocalToneMapSupported,
          "sharpness": raw.sharpnessAmount, "localToneMap": raw.localToneMapAmount]
      } else {
        guard let image = CIImage(contentsOf: inputURL, options: [.applyOrientationProperty: true]) else {
          throw CalibrationError.invalid("Unable to decode input")
        }
        source = image
      }
      let current = compiled(profile, preview: preview)
      let scene = current.unified ? CameraSceneContext.analyze(source) : .neutral
      let image = CameraDNARenderer.apply(current, to: source, finalPhoto: !preview, scene: scene)
      guard let cg = CameraEngineGPU.ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CameraEngineGPU.sRGBColorSpace),
            let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw CalibrationError.invalid("Unable to create reference output")
      }
      CGImageDestinationAddImage(destination, cg, nil)
      try require(CGImageDestinationFinalize(destination), "PNG encoding failed")
      try writeJSON(["rendererVersion": CameraDNARenderer.rendererVersion,
        "colorContract": CameraDNARenderer.colorContract, "width": cg.width, "height": cg.height,
        "elapsedMs": Date().timeIntervalSince(start) * 1000, "source": sourceInfo, "scene": scene.dictionary,
        "profileId": profile["id"] ?? "", "colorContract": current.colorContract], path: nil)
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
    }
  }
}
