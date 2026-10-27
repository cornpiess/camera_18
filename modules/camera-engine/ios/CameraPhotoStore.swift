import AVFoundation
import Photos
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

// API contracts: Apple WWDC23/10105 (proxy -> PhotoKit -> final),
// WWDC26/304 (.quality + 24MP), PHContentEditingOutput (same-asset recipe).

/// One durable job and one Photos asset per exposure. A proxy is NEVER rendered.
/// Queue ownership includes every callback; no semaphore blocks PhotoKit or the UI.
final class CameraPhotoStore {
  static let shared = CameraPhotoStore()
  typealias Completion = (Result<[String: Any], CameraEngineError>, String?) -> Void
  var eventSink: (([String: Any]) -> Void)?
  private let queue = DispatchQueue(label: "camera-engine.photo-store", qos: .userInitiated)
  private let fm = FileManager.default
  private var active = false
  private var activeAttempt: String?
  private let capacityLock = NSLock()
  private var pendingCount = 0
  private var attempted = Set<String>()
  private var callbacks: [String: Completion] = [:]
  private static let adjustmentID = "com.cornpiess.camera18.recipe"
  private var directory: URL {
    fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Camera18Pending", isDirectory: true)
  }

  private struct Job: Codable {
    let id: String
    let createdAt: Date
    let proxy: Bool
    let profileData: Data
    let diagnosticsData: Data
    var flattened: Bool = false
    var assetID: String?
    var lastError: String?
    var attemptID: String? // in-memory callback lease; not persisted
    enum CodingKeys: String, CodingKey {
      case id, createdAt, proxy, profileData, diagnosticsData, flattened, assetID, lastError
    }
  }

  static var canReadOwnPhotos: Bool {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    return status == .authorized || status == .limited
  }

  /// Ask once on first use. Denying read access keeps direct quality capture usable.
  static func authorize(completion: @escaping () -> Void) {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in completion() }
    } else { completion() }
  }

  /// One recovery pass at launch / foreground, never a polling or retry loop.
  func resume() {
    queue.async { self.attempted.removeAll(); self.updateCapacity(); self.drain() }
  }

  private func folder(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
  private func sourceURL(_ job: Job) -> URL { folder(job.id).appendingPathComponent("source.data") }
  private func save(_ job: Job) throws {
    try JSONEncoder().encode(job).write(to: folder(job.id).appendingPathComponent("job.json"), options: .atomic)
  }
  private func jobs() -> [Job] {
    let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return folders.compactMap { url in
      guard let data = try? Data(contentsOf: url.appendingPathComponent("job.json")) else { return nil }
      return try? JSONDecoder().decode(Job.self, from: data)
    }.sorted { $0.createdAt < $1.createdAt }
  }

  func accept(data: Data, proxy: Bool, captureID: String, profile: [String: Any],
              diagnostics: [String: Any], completion: @escaping Completion) {
    queue.async {
      do {
        // The ID comes from native UUID generation, never a user-supplied file path.
        let job = Job(id: captureID, createdAt: Date(), proxy: proxy,
          profileData: try JSONSerialization.data(withJSONObject: profile, options: .sortedKeys),
          diagnosticsData: try JSONSerialization.data(withJSONObject: diagnostics, options: .sortedKeys))
        try self.fm.createDirectory(at: self.folder(job.id), withIntermediateDirectories: true)
        try data.write(to: self.sourceURL(job), options: .atomic)
        try self.save(job)
        self.callbacks[job.id] = completion
        self.updateCapacity()
        self.drain()
      } catch {
        // Never delete a written source on failure; recoverable data is retained.
        DispatchQueue.main.async { completion(.failure(.saveFailed), error.localizedDescription) }
      }
    }
  }

  var canAcceptCapture: Bool {
    capacityLock.lock(); defer { capacityLock.unlock() }
    return pendingCount < 8
  }
  private func updateCapacity() {
    let count = jobs().count
    capacityLock.lock(); pendingCount = count; capacityLock.unlock()
  }

  private func drain() {
    guard !active, var job = jobs().first(where: { !attempted.contains($0.id) }) else { return }
    active = true
    job.attemptID = UUID().uuidString
    activeAttempt = job.attemptID
    attempted.insert(job.id)
    queue.asyncAfter(deadline: .now() + 120) {
      guard self.isActive(job) else { return }
      // Reload the journal: a create transaction may already have persisted its ID.
      var latest = self.jobs().first(where: { $0.id == job.id }) ?? job
      latest.attemptID = job.attemptID
      self.complete(latest, error: .processingFailed, detail: "Photo processing paused; the source is retained for the next resume.")
    }
    if job.assetID != nil { loadFinal(job); return }
    // Both paths create the original first, so a failed style edit cannot lose it.
    let addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if !Self.canReadOwnPhotos && addStatus == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in self.queue.async { self.createOriginal(job) } }
    } else { createOriginal(job) }
  }

  private func isActive(_ job: Job) -> Bool { active && activeAttempt == job.attemptID }

  private func createOriginal(_ originalJob: Job) {
    guard isActive(originalJob) else { return }
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard Self.canReadOwnPhotos || status == .authorized || status == .limited else {
      complete(originalJob, error: .photoPermissionDenied, detail: "Photo access is unavailable; the captured source is retained.")
      return
    }
    guard !originalJob.proxy || Self.canReadOwnPhotos else {
      complete(originalJob, error: .photoPermissionDenied, detail: "Reading the final deferred photo requires photo access; the proxy is retained.")
      return
    }
    var job = originalJob
    if !Self.canReadOwnPhotos, !job.proxy, profile(job)["passthrough"] as? Bool != true {
      do {
        let destination = folder(job.id).appendingPathComponent("rendered.data")
        do { try render(job, source: sourceURL(job), destination: destination, type: "public.heic") }
        catch { try render(job, source: sourceURL(job), destination: destination, type: "public.jpeg") }
        job.flattened = true
        try save(job)
      } catch { complete(job, error: .processingFailed, detail: error.localizedDescription); return }
    }
    var journalError: Error?
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      job.assetID = request.placeholderForCreatedAsset?.localIdentifier
      // Persist the identifier BEFORE submitting the transaction, so restart never
      // blindly creates a second asset after a successful but unacknowledged save.
      do {
        guard job.assetID != nil else { throw CameraEngineError.saveFailed }
        try self.save(job)
        let options = PHAssetResourceCreationOptions()
        if !job.proxy {
          let resource = job.flattened ? self.folder(job.id).appendingPathComponent("rendered.data") : self.sourceURL(job)
          if let imageSource = CGImageSourceCreateWithURL(resource as CFURL, nil), let type = CGImageSourceGetType(imageSource) {
            options.uniformTypeIdentifier = type as String
            options.originalFilename = "Camera18-\(job.id)." + ((type as String) == "public.jpeg" ? "jpg" : "heic")
          }
        }
        if job.proxy {
          if #available(iOS 17.0, *) { request.addResource(with: .photoProxy, fileURL: self.sourceURL(job), options: options) }
        } else { request.addResource(with: .photo, fileURL: job.flattened ? self.folder(job.id).appendingPathComponent("rendered.data") : self.sourceURL(job), options: options) }
      } catch { journalError = error }
    }) { success, error in
      self.queue.async {
        guard self.isActive(job) else { return }
        guard success, journalError == nil else {
          // A confirmed transaction failure is safe to retry on the next resume.
          job.assetID = nil
          try? self.save(job)
          self.complete(job, error: .saveFailed, detail: (journalError ?? error)?.localizedDescription ?? "Original photo save failed.")
          return
        }
        if job.flattened { self.deliver(job, url: self.folder(job.id).appendingPathComponent("rendered.data"), fallback: false) }
        else if Self.canReadOwnPhotos { self.loadFinal(job) }
        else { self.deliver(job, url: self.sourceURL(job), fallback: false) }
      }
    }
  }

  private func profile(_ job: Job) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: job.profileData)) as? [String: Any] ?? [:]
  }

  private func loadFinal(_ job: Job) {
    guard isActive(job) else { return }
    if job.flattened {
      deliver(job, url: folder(job.id).appendingPathComponent("rendered.data"), fallback: false)
      return
    }
    guard Self.canReadOwnPhotos, let id = job.assetID,
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
      // Missing could mean deleted, restricted, or interrupted transaction. Preserve
      // the source and stop; automatically creating another asset risks duplicates.
      complete(job, error: .photoPermissionDenied, detail: "The saved original is not accessible; pending work is retained.")
      return
    }
    let options = PHContentEditingInputRequestOptions()
    options.isNetworkAccessAllowed = true
    options.canHandleAdjustmentData = { _ in true }
    asset.requestContentEditingInput(with: options) { input, info in
      self.queue.async {
        guard self.isActive(job) else { return }
        guard let input, let url = input.fullSizeImageURL else {
          self.complete(job, error: .processingFailed, detail: "Final Apple photo unavailable: \(String(describing: info[PHContentEditingInputErrorKey]))")
          return
        }
        // This request obtains the finalized image, including deferred processing.
        // If a crash occurred after the edit committed, recognize it and finish once.
        if let adjustment = input.adjustmentData,
           let recipe = (try? JSONSerialization.jsonObject(with: adjustment.data)) as? [String: Any],
           recipe["captureID"] as? String == job.id {
          let rendered = self.folder(job.id).appendingPathComponent("final.data")
          if self.fm.fileExists(atPath: rendered.path) { self.deliver(job, url: rendered, fallback: false) }
          else { self.complete(job, error: .processingFailed, detail: "Committed style output is missing; the edited photo remains in Photos.") }
          return
        }
        guard input.adjustmentData == nil else {
          self.complete(job, error: .processingFailed, detail: "The photo was edited elsewhere; Camera18 will not overwrite that edit.")
          return
        }
        let profile = self.profile(job)
        if profile["passthrough"] as? Bool == true {
          self.deliver(job, url: url, fallback: false)
          return
        }
        do {
          let output = PHContentEditingOutput(contentEditingInput: input)
          let type: UTType
          let destination: URL
          if #available(iOS 17.0, *), output.supportedRenderedContentTypes.contains(.heic) {
            type = .heic
            destination = try output.renderedContentURL(for: type)
          } else {
            type = .jpeg
            destination = output.renderedContentURL
          }
          let rendered = self.folder(job.id).appendingPathComponent("final.data")
          try self.render(job, source: url, destination: rendered, type: type.identifier)
          try self.fm.copyItem(at: rendered, to: destination)
          output.adjustmentData = PHAdjustmentData(formatIdentifier: Self.adjustmentID, formatVersion: "1",
            data: try JSONSerialization.data(withJSONObject: ["captureID": job.id, "profile": profile,
              "rendererVersion": CameraDNARenderer.rendererVersion]))
          PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
          }) { success, error in
            self.queue.async {
              guard self.isActive(job) else { return }
              guard success else {
                self.complete(job, error: .saveFailed, detail: error?.localizedDescription ?? "Style save failed; the original remains in Photos.")
                return
              }
              // Keep an app-owned final file; PhotoKit owns its editing temp URLs.
              self.deliver(job, url: rendered, fallback: false)
            }
          }
        } catch { self.complete(job, error: .processingFailed, detail: error.localizedDescription) }
      }
    }
  }

  private func render(_ job: Job, source: URL, destination: URL, type: String) throws {
    guard let dataSource = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
      throw CameraEngineError.processingFailed
    }
    var recipe = profile(job)
    // A single private cache namespace prevents preview/import edits racing a capture
    // snapshot, while keeping renderer caches bounded (not one entry per photograph).
    recipe["id"] = "__camera18_final_snapshot"
    // Serialize invalidate+compile here; snapshots cannot pick up a later profile edit.
    CameraDNARenderer.invalidateCompiledProfile(recipe)
    let compiled = CameraDNARenderer.compile(recipe, normalizer: CameraInputNormalizer.definition(for: .processedPhoto))
    let rendered = CameraDNARenderer.apply(compiled, to: image, finalPhoto: true)
    guard rendered.extent.integral == image.extent.integral else { throw CameraEngineError.processingFailed }
    let metadata = CGImageSourceCopyPropertiesAtIndex(dataSource, 0, nil) as? [AnyHashable: Any]
    guard let encoded = Self.encodedRepresentation(rendered, metadata: metadata,
      colorSpace: CameraEngineGPU.sRGBColorSpace, quality: 0.95,
      type: type as CFString) else {
      throw CameraEngineError.processingFailed
    }
    try encoded.write(to: destination, options: .atomic)
  }

  private func deliver(_ job: Job, url: URL, fallback: Bool) {
    guard isActive(job) else { return }
    do {
      let source = CGImageSourceCreateWithURL(url as CFURL, nil)
      let type = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String } ?? "public.jpeg"
      let final = CameraTempFiles.makeFinalURL(pathExtension: type == "public.heic" || type == "public.heif" ? "heif" : "jpg")
      let thumb = CameraTempFiles.makeThumbURL()
      CameraTempFiles.track([final, thumb])
      try fm.copyItem(at: url, to: final)
      var thumbURI: Any = NSNull()
      if let source, let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 512,
      ] as CFDictionary), let dest = CGImageDestinationCreateWithURL(thumb as CFURL, "public.jpeg" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        if CGImageDestinationFinalize(dest) {
          thumbURI = CameraTempFiles.persistLatestThumbnail(from: thumb)?.absoluteString ?? thumb.absoluteString
        }
      }
      CameraTempFiles.keep([final, thumb])
      var facts = (try? JSONSerialization.jsonObject(with: job.diagnosticsData)) as? [String: Any] ?? [:]
      if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        facts["actualWidth"] = properties[kCGImagePropertyPixelWidth as String]
        facts["actualHeight"] = properties[kCGImagePropertyPixelHeight as String]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        facts["iso"] = exif["ISOSpeedRatings"]
        facts["exposureTime"] = exif["ExposureTime"]
        facts["actualAperture"] = exif["FNumber"]
        facts["lensModel"] = exif["LensModel"]
      }
      facts["fileUri"] = final.absoluteString
      facts["thumbnailUri"] = thumbURI
      facts["assetLocalIdentifier"] = job.assetID ?? ""
      facts["codec"] = type
      facts["jobID"] = job.id
      facts["processingFallback"] = fallback
      facts["ok"] = true
      facts["recovered"] = callbacks[job.id] == nil
      NSLog("[CameraEngine][Photo] id=%@ delivery=%@ dimensions=%@x%@", job.id,
        String(describing: facts["delivery"] ?? "direct"), String(describing: facts["actualWidth"] ?? 0),
        String(describing: facts["actualHeight"] ?? 0))
      if job.flattened {
        // Read-denied fallback still preserves the clean original and recipe locally.
        // It cannot attach an original resource to an existing Photos asset without
        // read access. The fallback is a single styled asset, not two visible photos.
        let archive = directory.deletingLastPathComponent().appendingPathComponent("Camera18Originals", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let target = archive.appendingPathComponent(job.id, isDirectory: true)
        if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: folder(job.id), to: target) }
        else { try fm.removeItem(at: folder(job.id)) }
      } else { try fm.removeItem(at: folder(job.id)) }
      let callback = callbacks.removeValue(forKey: job.id)
      DispatchQueue.main.async {
        if let callback { callback(.success(facts), nil) }
        else { self.eventSink?(facts) }
      }
      updateCapacity()
      active = false
      activeAttempt = nil
      drain()
    } catch { complete(job, error: .saveFailed, detail: error.localizedDescription) }
  }

  private func complete(_ originalJob: Job, error: CameraEngineError, detail: String) {
    guard isActive(originalJob) else { return }
    attempted.insert(originalJob.id)
    var job = originalJob
    job.lastError = detail
    try? save(job)
    let callback = callbacks.removeValue(forKey: job.id)
    DispatchQueue.main.async {
      if let callback { callback(.failure(error), detail) }
      else {
        let facts = (try? JSONSerialization.jsonObject(with: job.diagnosticsData)) as? [String: Any] ?? [:]
        self.eventSink?(["ok": false, "recovered": true, "captureID": facts["captureID"] ?? job.id, "errorCode": error.rawValue, "detail": detail])
      }
    }
    active = false
    activeAttempt = nil
    drain()
  }
  static func encodedRepresentation(_ image: CIImage, metadata: [AnyHashable: Any]?, colorSpace: CGColorSpace, quality: Double, type: CFString) -> Data? {
    guard let cgImage = CameraEngineGPU.ciContext.createCGImage(image, from: image.extent, format: CIFormat.RGBA8, colorSpace: colorSpace) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return nil }

    let sourceProperties = cfProperties(metadata)
    // Export is SDR sRGB. Carry photographic metadata, never old color profiles,
    // maker-specific HDR instructions or auxiliary-image / gain-map metadata.
    var properties: [CFString: Any] = [:]
    for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
      properties[key] = sourceProperties[key]
    }
    properties[kCGImageDestinationLossyCompressionQuality] = quality
    properties[kCGImagePropertyOrientation] = 1
    var exif = cfProperties(properties[kCGImagePropertyExifDictionary])
    exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
    exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
    // Keep Apple's delivered exposure / aperture metadata. A preview-time iris
    // reading is not proof of the aperture used by a multi-frame capture.
    // The rendered pixels are ALREADY upright (orientation applied during CIImage decode),
    // but the carried-over EXIF block still says "rotated" — Photos honors that tag and
    // displays landscape shots as portrait. Pin the EXIF orientation to 1. (ImageIO has no
    // named constant for the EXIF-dictionary orientation key; it is literally "Orientation".)
    exif["Orientation" as CFString] = 1
    properties[kCGImagePropertyExifDictionary] = exif
    var tiff = cfProperties(properties[kCGImagePropertyTIFFDictionary])
    tiff[kCGImagePropertyTIFFOrientation] = 1
    properties[kCGImagePropertyTIFFDictionary] = tiff

    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  private static func cfProperties(_ value: Any?) -> [CFString: Any] {
    guard let dict = value as? [AnyHashable: Any] else { return [:] }
    var result: [CFString: Any] = [:]
    for (key, item) in dict {
      // Cast through String: a conditional downcast straight to the CF type is a hard error
      // under Swift 6, and String bridges to CFString unconditionally.
      if let stringKey = key as? String { result[stringKey as CFString] = item }
    }
    return result
  }


}
