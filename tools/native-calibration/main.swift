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
  try writeJSON(["rendererVersion": CameraDNARenderer.rendererVersion,
    "colorContract": CameraDNARenderer.colorContract, "identityMaxRGBError": identityError,
    "sharedColorMaxRGBError": sharedError, "status": "pass"], path: nil)
}

@main enum CameraCalibrationCLI {
  static func main() {
    do {
      let args = Array(CommandLine.arguments.dropFirst())
      if args == ["self-test"] { try selfTest(); return }
      try require(args.count == 7 && ["render", "probes"].contains(args[0]),
        "Usage: native-calibration self-test | (render|probes) <profiles.json> <id> <lut-dir> <input> <output> <preview|final>")
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
        colorProfile["texture"] = texture
        let input = try readProbes(args[4])
        try writeJSON(["rendererVersion": CameraDNARenderer.rendererVersion,
          "colorContract": CameraDNARenderer.colorContract, "mode": args[6],
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
      guard let source = CIImage(contentsOf: inputURL, options: [.applyOrientationProperty: true]) else {
        throw CalibrationError.invalid("Unable to decode input")
      }
      let start = Date()
      let image = CameraDNARenderer.apply(compiled(profile, preview: preview), to: source, finalPhoto: !preview)
      guard let cg = CameraEngineGPU.ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CameraEngineGPU.sRGBColorSpace),
            let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
        throw CalibrationError.invalid("Unable to create reference output")
      }
      CGImageDestinationAddImage(destination, cg, nil)
      try require(CGImageDestinationFinalize(destination), "PNG encoding failed")
      try writeJSON(["rendererVersion": CameraDNARenderer.rendererVersion,
        "colorContract": CameraDNARenderer.colorContract, "width": cg.width, "height": cg.height,
        "elapsedMs": Date().timeIntervalSince(start) * 1000], path: nil)
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
    }
  }
}
