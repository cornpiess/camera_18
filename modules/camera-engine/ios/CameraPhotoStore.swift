import AVFoundation
import Photos
import CoreImage
import ImageIO
import UIKit
import UniformTypeIdentifiers

// API contracts: Apple WWDC23/10105 (proxy -> PhotoKit -> final),
// WWDC26/304 (.quality + 24MP), PHContentEditingOutput (same-asset recipe).

/// One durable job and one Photos asset per exposure. Direct captures are styled
/// locally before asset creation; Photos read/edit access never gates a new photo.
/// Legacy proxy journals are still finalized, and a proxy is NEVER rendered.
/// Queue ownership includes every callback; no semaphore blocks PhotoKit or the UI.
final class CameraPhotoStore {
  static let shared = CameraPhotoStore()
  typealias Completion = (Result<[String: Any], CameraEngineError>, String?) -> Void
  var stateSink: (([String: Any]) -> Void)?
  private var suspended = false
  private var executionLease: UIBackgroundTaskIdentifier = .invalid // main thread only
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
    var processingFallback: Bool?
    var renderMetadata: Data?
    var assetID: String?
    var originalConfirmed: Bool?
    var lastError: String?
    var attempts: Int? // failed re-attempts that already ran; nil for a first pass
    var attemptID: String? // in-memory callback lease; not persisted
    enum CodingKeys: String, CodingKey {
      case id, createdAt, proxy, profileData, diagnosticsData, flattened, processingFallback, renderMetadata, assetID, originalConfirmed, lastError, attempts
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

  /// New production photos need add access only. Read access is requested by
  /// explicit Photos operations, not imposed on the camera's capture path.
  static func authorizeSaving(completion: @escaping () -> Void) {
    if PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in completion() }
    } else { completion() }
  }

  /// One recovery pass at launch / foreground, never a polling or retry loop.
  func resume() {
    ensureExecutionLease()
    queue.async {
      self.suspended = false
      self.replayOutcomes()
      // Repeated lifecycle notifications / retry taps must not reset the pass
      // while an existing transaction still owns it.
      if !self.active { self.attempted.removeAll() }
      self.updateCapacity()
      self.drain()
    }
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
    ensureExecutionLease()
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
    let count = jobs().filter { $0.lastError == nil }.count
    capacityLock.lock(); pendingCount = count; capacityLock.unlock()
    publishState()
  }

  private func drain() {
    guard !active, !suspended else { return }
    guard var job = jobs().first(where: { !attempted.contains($0.id) }) else { endExecutionLease(); publishState(); return }
    // Only re-attempts of an already-failed job count toward the retention limit.
    if job.lastError != nil { job.attempts = (job.attempts ?? 0) + 1 }
    job.lastError = nil
    try? save(job)
    active = true
    job.attemptID = UUID().uuidString
    activeAttempt = job.attemptID
    attempted.insert(job.id)
    updateCapacity()
    queue.asyncAfter(deadline: .now() + 120) {
      guard self.isActive(job) else { return }
      // Reload the journal: a create transaction may already have persisted its ID.
      var latest = self.jobs().first(where: { $0.id == job.id }) ?? job
      latest.attemptID = job.attemptID
      self.complete(latest, error: .processingFailed, detail: "Photo processing paused; the source is retained for the next resume.")
    }
    if job.assetID != nil { loadFinal(job); return }
    // New direct captures render locally, then create one complete Photos asset.
    // Only legacy proxy / already-created journals need Photos finalization.
    let addStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    if !Self.canReadOwnPhotos && addStatus == .notDetermined {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in self.queue.async { self.createAsset(job) } }
    } else { createAsset(job) }
  }

  private func isActive(_ job: Job) -> Bool { active && activeAttempt == job.attemptID }

  private func createAsset(_ originalJob: Job) {
    guard isActive(originalJob) else { return }
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard Self.canReadOwnPhotos || status == .authorized || status == .limited else {
      complete(originalJob, error: .photoPermissionDenied, detail: "Photo access is unavailable; the captured source is retained.")
      return
    }
    guard !originalJob.proxy || Self.canReadOwnPhotos else {
      complete(originalJob, error: .photoReadDenied, detail: "Reading the final deferred photo requires photo access; the proxy is retained.")
      return
    }
    var job = originalJob
    if !job.proxy, profile(job)["passthrough"] as? Bool != true {
      do {
        let destination = folder(job.id).appendingPathComponent("rendered.data")
        let scene: CameraSceneContext
        do { scene = try render(job, source: sourceURL(job), destination: destination, type: "public.heic") }
        catch { scene = try render(job, source: sourceURL(job), destination: destination, type: "public.jpeg") }
        job.renderMetadata = try JSONSerialization.data(withJSONObject: [
          "rendererVersion": CameraDNARenderer.rendererVersion, "scene": scene.dictionary,
          "colorContract": (profile(job)["recipe"] as? [String: Any])?["colorContract"] ?? CameraDNARenderer.legacyColorContract,
        ])
        job.flattened = true
        job.processingFallback = false
        try save(job)
      } catch {
        // Taking a real photo must not depend on a style filter/encoder succeeding.
        // Preserve Apple's complete source and explicitly report the fallback.
        job.flattened = false
        job.processingFallback = true
        do { try save(job) }
        catch { complete(job, error: .saveFailed, detail: error.localizedDescription); return }
        NSLog("[CameraEngine][Photo] id=%@ style failed; saving Apple source: %@", job.id, error.localizedDescription)
      }
    }
    var journalError: Error?
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      do {
        let options = PHAssetResourceCreationOptions()
        if !job.proxy {
          let resource = job.flattened ? self.folder(job.id).appendingPathComponent("rendered.data") : self.sourceURL(job)
          if let imageSource = CGImageSourceCreateWithURL(resource as CFURL, nil), let type = CGImageSourceGetType(imageSource) {
            options.uniformTypeIdentifier = type as String
            options.originalFilename = "Camera18-\(job.id)." + ((type as String) == "public.jpeg" ? "jpg" : "heic")
          }
        }
        if job.proxy {
          // Match Apple's deferred-photo contract: pass the unmodified proxy bytes.
          // The private journal's .data suffix must not determine a Photos UTI.
          if #available(iOS 17.0, *) {
            request.addResource(with: .photoProxy, data: try Data(contentsOf: self.sourceURL(job)), options: nil)
          } else { throw CameraEngineError.processingFailed }
        } else { request.addResource(with: .photo, fileURL: job.flattened ? self.folder(job.id).appendingPathComponent("rendered.data") : self.sourceURL(job), options: options) }
        // Register the resource BEFORE asking for its placeholder. An empty asset
        // request is not a valid new image and may not provide a placeholder.
        job.assetID = request.placeholderForCreatedAsset?.localIdentifier
        guard job.assetID != nil else { throw CameraEngineError.saveFailed }
        // Persist before the change block completes; ambiguous completion never
        // justifies creating a duplicate asset on the next launch.
        try self.save(job)
      } catch { journalError = error }
    }) { success, error in
      self.queue.async {
        guard self.isActive(job) else { return }
        guard success else {
          // A confirmed transaction failure is safe to retry on the next resume.
          job.assetID = nil
          try? self.save(job)
          self.complete(job, error: .saveFailed, detail: (journalError ?? error)?.localizedDescription ?? "Original photo save failed.")
          return
        }
        job.originalConfirmed = true
        try? self.save(job)
        if let journalError {
          self.complete(job, error: .saveFailed, detail: journalError.localizedDescription)
          return
        }
        if job.flattened { self.deliver(job, url: self.folder(job.id).appendingPathComponent("rendered.data"), fallback: false) }
        else if !job.proxy { self.deliver(job, url: self.sourceURL(job), fallback: job.processingFallback == true) }
        else { self.loadFinal(job) }
      }
    }
  }

  private func profile(_ job: Job) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: job.profileData)) as? [String: Any] ?? [:]
  }

  private func loadFinal(_ job: Job) {
    guard isActive(job) else { return }
    if job.flattened {
      // A placeholder journaled before process death is not proof of a committed
      // transaction. Confirm it when possible; never report an ambiguous save as
      // successful, or create a second visible asset just to resolve ambiguity.
      if job.originalConfirmed != true {
        guard Self.canReadOwnPhotos, let id = job.assetID,
              PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil else {
          complete(job, error: .saveFailed, detail: "The previous save could not be confirmed; the finished photo is retained.")
          return
        }
      }
      deliver(job, url: folder(job.id).appendingPathComponent("rendered.data"), fallback: false)
      return
    }
    if !job.proxy, job.originalConfirmed == true,
       profile(job)["passthrough"] as? Bool == true || job.processingFallback == true {
      deliver(job, url: sourceURL(job), fallback: job.processingFallback == true)
      return
    }
    guard Self.canReadOwnPhotos, let id = job.assetID,
          let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
      // Missing could mean deleted, restricted, or interrupted transaction. Preserve
      // the source and stop; automatically creating another asset risks duplicates.
      complete(job, error: Self.canReadOwnPhotos ? .processingFailed : .photoReadDenied,
        detail: "The saved original is not accessible; pending work is retained.")
      return
    }
    var job = job
    job.originalConfirmed = true
    try? save(job)
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
          let renderScene = try self.render(job, source: url, destination: rendered, type: type.identifier)
          // PhotoKit may already own a file at its output URL. Atomic replacement
          // also makes recovery safe; copyItem rejects an existing destination.
          try Data(contentsOf: rendered).write(to: destination, options: .atomic)
          output.adjustmentData = PHAdjustmentData(formatIdentifier: Self.adjustmentID, formatVersion: "1",
            data: try JSONSerialization.data(withJSONObject: ["captureID": job.id, "profile": profile,
              "rendererVersion": CameraDNARenderer.rendererVersion, "scene": renderScene.dictionary,
              "colorContract": (profile["recipe"] as? [String: Any])?["colorContract"] ?? CameraDNARenderer.legacyColorContract]))
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

  @discardableResult
  private func render(_ job: Job, source: URL, destination: URL, type: String) throws -> CameraSceneContext {
    let start = ProcessInfo.processInfo.systemUptime
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
    let diagnostics = (try? JSONSerialization.jsonObject(with: job.diagnosticsData)) as? [String: Any] ?? [:]
    let exposureScene = CameraSceneContext(dictionary: diagnostics["renderScene"] as? [String: Any] ?? [:])
    let scene = compiled.unified ? CameraSceneContext.analyze(image).bounded(by: exposureScene) : .neutral
    let rendered = CameraDNARenderer.apply(compiled, to: image, finalPhoto: true, scene: scene)
    guard rendered.extent.integral == image.extent.integral else { throw CameraEngineError.processingFailed }
    let metadata = CGImageSourceCopyPropertiesAtIndex(dataSource, 0, nil) as? [AnyHashable: Any]
    guard let encoded = Self.encodedRepresentation(rendered, metadata: metadata,
      colorSpace: CameraEngineGPU.sRGBColorSpace, quality: 0.95,
      type: type as CFString) else {
      throw CameraEngineError.processingFailed
    }
    try encoded.write(to: destination, options: .atomic)
    CameraRenderTimings.record(.photoProcessing, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    return scene
  }

  private func deliver(_ job: Job, url: URL, fallback: Bool) {
    guard isActive(job) else { return }
    do {
      let latestDirectory = directory.deletingLastPathComponent().appendingPathComponent("Camera18Latest", isDirectory: true)
      let manifest = latestDirectory.appendingPathComponent("latest.json")
      let previousData = try? Data(contentsOf: manifest)
      let previous = previousData.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
      let diagnostics = (try? JSONSerialization.jsonObject(with: job.diagnosticsData)) as? [String: Any] ?? [:]
      let isLatest = (diagnostics["capturedAt"] as? Double ?? 0) >= (previous?["capturedAt"] as? Double ?? 0)
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
          thumbURI = isLatest ? (CameraTempFiles.persistLatestThumbnail(from: thumb)?.absoluteString ?? thumb.absoluteString) : thumb.absoluteString
        }
      }
      CameraTempFiles.keep([final, thumb])
      var facts = diagnostics
      if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
        facts["actualWidth"] = properties[kCGImagePropertyPixelWidth as String]
        facts["actualHeight"] = properties[kCGImagePropertyPixelHeight as String]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        facts["iso"] = exif["ISOSpeedRatings"]
        facts["exposureTime"] = exif["ExposureTime"]
        facts["actualAperture"] = exif["FNumber"]
        facts["lensModel"] = exif["LensModel"]
      }
      try fm.createDirectory(at: latestDirectory, withIntermediateDirectories: true)
      let persistent = latestDirectory.appendingPathComponent(job.id).appendingPathExtension(final.pathExtension)
      if !fm.fileExists(atPath: persistent.path) { try fm.copyItem(at: final, to: persistent) }
      facts["profileName"] = profile(job)["displayName"] ?? profile(job)["name"]
      facts["fileUri"] = persistent.absoluteString
      facts["thumbnailUri"] = thumbURI
      facts["assetLocalIdentifier"] = job.assetID ?? ""
      facts["codec"] = type
      facts["jobID"] = job.id
      facts["processingFallback"] = fallback
      facts["ok"] = true
      facts["terminal"] = true
      facts["originalSaved"] = true
      facts["recovered"] = callbacks[job.id] == nil
      if isLatest { try JSONSerialization.data(withJSONObject: facts).write(to: manifest, options: .atomic) }
      try persistOutcome(facts, id: job.id)
      // Only derived full-size copies are cleaned. Original-only archives are never automatic cleanup targets.
      let copies = (try? fm.contentsOfDirectory(at: latestDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      let latestURI = isLatest ? persistent.absoluteString : previous?["fileUri"] as? String
      for copy in copies where copy != persistent && copy.absoluteString != latestURI && copy.pathExtension != "json" {
        try? fm.removeItem(at: copy)
      }
      NSLog("[CameraEngine][Photo] id=%@ delivery=%@ dimensions=%@x%@", job.id,
        String(describing: facts["delivery"] ?? "direct"), String(describing: facts["actualWidth"] ?? 0),
        String(describing: facts["actualHeight"] ?? 0))
      do {
        if job.flattened {
          // Every direct styled capture preserves its clean source and recipe here.
          // Photos receives one finished asset, with no readback or edit transaction.
          let archive = directory.deletingLastPathComponent().appendingPathComponent("Camera18Originals", isDirectory: true)
          try fm.createDirectory(at: archive, withIntermediateDirectories: true)
          let target = archive.appendingPathComponent(job.id, isDirectory: true)
          if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: folder(job.id), to: target) }
          else { try fm.removeItem(at: folder(job.id)) }
          // Only the clean source and recipe need long-term retention. The styled
          // result is already in Photos / latest; do not archive a second copy.
          for name in ["rendered.data", "final.data"] { try? fm.removeItem(at: target.appendingPathComponent(name)) }
        } else { try fm.removeItem(at: folder(job.id)) }
      } catch { NSLog("[CameraEngine][Photo] saved; retained journal after cleanup failure: %@", error.localizedDescription) }
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
    var facts = (try? JSONSerialization.jsonObject(with: job.diagnosticsData)) as? [String: Any] ?? [:]
    facts["ok"] = false
    facts["terminal"] = false
    facts["retained"] = true
    facts["originalSaved"] = job.originalConfirmed == true
    facts["errorCode"] = error.rawValue
    facts["detail"] = detail
    facts["recovered"] = callback == nil
    NSLog("[CameraEngine][Photo] id=%@ save=%@ originalSaved=%@ detail=%@", job.id,
      error.rawValue, String(job.originalConfirmed == true), detail)
    // THREE-STRIKE RETENTION: a job that already failed three re-attempts will keep
    // failing under the same conditions, and every silent re-failure keeps the
    // delivery pill stuck ("tap to retry" that can never succeed — including legacy
    // proxy jobs, which the recovery sheet deliberately refuses to stop). Close it:
    // persist a terminal outcome, move the journal to Camera18Originals (recovery
    // sheet keeps export/cleanup; nothing is deleted), clear the pill, settle JS.
    if (job.attempts ?? 0) >= 3 {
      do {
        facts["terminal"] = true
        // Persist the TERMINAL form: launch replay must settle and ack exactly once.
        try persistOutcome(facts, id: job.id)
        let archive = directory.deletingLastPathComponent().appendingPathComponent("Camera18Originals", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let target = archive.appendingPathComponent(job.id, isDirectory: true)
        if !fm.fileExists(atPath: target.path) { try fm.moveItem(at: folder(job.id), to: target) }
        NSLog("[CameraEngine][Photo] id=%@ retained terminally after %@ failed re-attempts", job.id, String(job.attempts ?? 0))
      } catch {
        facts["terminal"] = false
        NSLog("[CameraEngine][Photo] id=%@ terminal retain failed: %@", job.id, error.localizedDescription)
      }
    }
    DispatchQueue.main.async {
      if let callback { callback(.success(facts), detail) }
      else { self.eventSink?(facts) }
    }
    updateCapacity()
    active = false
    activeAttempt = nil
    drain()
  }
  private var outcomeDirectory: URL { directory.deletingLastPathComponent().appendingPathComponent("Camera18Outcomes", isDirectory: true) }
  private func persistOutcome(_ facts: [String: Any], id: String) throws {
    try fm.createDirectory(at: outcomeDirectory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: facts).write(to: outcomeDirectory.appendingPathComponent(id).appendingPathExtension("json"), options: .atomic)
  }
  private func outcomes() -> [[String: Any]] {
    let urls = (try? fm.contentsOfDirectory(at: outcomeDirectory, includingPropertiesForKeys: nil)) ?? []
    return urls.compactMap { url in
      guard let data = try? Data(contentsOf: url) else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
  }
  private func replayOutcomes() {
    for var facts in outcomes() {
      facts["recovered"] = true
      if let id = facts["jobID"] as? String, fm.fileExists(atPath: deletedURL(id).path) {
        facts["previewDeleted"] = true
        facts.removeValue(forKey: "fileUri"); facts.removeValue(forKey: "thumbnailUri")
      }
      DispatchQueue.main.async { self.eventSink?(facts) }
    }
  }
  func acknowledge(_ id: String) {
    guard UUID(uuidString: id) != nil else { return }
    queue.async { try? self.fm.removeItem(at: self.outcomeDirectory.appendingPathComponent(id).appendingPathExtension("json")) }
  }

  private func ensureExecutionLease() {
    DispatchQueue.main.async {
      guard self.executionLease == .invalid else { return }
      self.executionLease = UIApplication.shared.beginBackgroundTask(withName: "Finish Camera18 photo") {
        self.queue.async {
          self.suspended = true
          self.activeAttempt = nil
          self.active = false
          self.publishState()
        }
        self.endExecutionLease()
      }
    }
  }
  private func endExecutionLease() {
    DispatchQueue.main.async {
      let lease = self.executionLease
      self.executionLease = .invalid
      if lease != .invalid { UIApplication.shared.endBackgroundTask(lease) }
    }
  }
  private func stateValue() -> [String: Any] {
    let all = jobs()
    let failed = all.filter { $0.lastError != nil }.count
    let originalDirectory = directory.deletingLastPathComponent().appendingPathComponent("Camera18Originals", isDirectory: true)
    let originals = (try? fm.contentsOfDirectory(at: originalDirectory, includingPropertiesForKeys: nil)) ?? []
    return ["processing": max(0, all.count - failed), "waiting": failed,
      "originals": originals.count, "paused": suspended,
      "originalSaved": all.filter { $0.originalConfirmed == true }.count,
      "captureIDs": all.compactMap { ((try? JSONSerialization.jsonObject(with: $0.diagnosticsData)) as? [String: Any])?["captureID"] as? String }
        + outcomes().compactMap { $0["captureID"] as? String }]
  }
  private func publishState() {
    let state = stateValue()
    DispatchQueue.main.async { self.stateSink?(state) }
  }
  func snapshot(_ completion: @escaping ([String: Any]) -> Void) {
    queue.async { completion(self.stateValue()) }
  }
  // Queue-owned lookup. Deletion markers survive interruption during latest.json
  // cleanup, and preserve the timestamp without a stale image.
  private func latestFacts() -> [String: Any]? {
    let manifest = directory.deletingLastPathComponent().appendingPathComponent("Camera18Latest/latest.json")
    guard let data = try? Data(contentsOf: manifest),
          var facts = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    if let id = facts["jobID"] as? String, fm.fileExists(atPath: deletedURL(id).path) {
      facts["previewDeleted"] = true
      facts.removeValue(forKey: "fileUri"); facts.removeValue(forKey: "thumbnailUri")
    }
    if facts["previewDeleted"] as? Bool == true { return facts }
    guard let uri = facts["fileUri"] as? String, let file = URL(string: uri), file.isFileURL,
          fm.fileExists(atPath: file.path) else { return nil }
    return facts
  }
  func latest(_ completion: @escaping ([String: Any]?) -> Void) {
    queue.async { completion(self.latestFacts()) }
  }

  private var viewerOpening = false // main thread only
  private func deletedURL(_ id: String) -> URL {
    directory.deletingLastPathComponent().appendingPathComponent("Camera18Deleted", isDirectory: true)
      .appendingPathComponent(id).appendingPathExtension("json")
  }

  /// Pin a full-size copy before presentation. Delivering another pending photo
  /// can clean derived latest files without changing/deleting this viewer's image.
  func showLatest(profileNames: [String: String], completion: @escaping (Result<[String: Any], CameraEngineError>) -> Void) {
    DispatchQueue.main.async {
      guard !self.viewerOpening, !CameraOrientationSubscriber.viewingPhoto else { completion(.failure(.captureBusy)); return }
      self.viewerOpening = true
      self.queue.async {
        var snapshot: (URL, [String: Any], UIImage)?
        let cache = self.fm.temporaryDirectory.appendingPathComponent("Camera18Viewer", isDirectory: true)
        do {
          guard var facts = self.latestFacts() else { throw CameraEngineError.processingFailed }
          guard facts["previewDeleted"] as? Bool != true, let uri = facts["fileUri"] as? String,
                let source = URL(string: uri), source.isFileURL else { throw CameraEngineError.processingFailed }
          try? self.fm.removeItem(at: cache) // no viewer is active; removes a crash's stale copy
          try self.fm.createDirectory(at: cache, withIntermediateDirectories: true)
          let file = cache.appendingPathComponent("photo").appendingPathExtension(source.pathExtension)
          try self.fm.copyItem(at: source, to: file)
          guard let image = UIImage(contentsOfFile: file.path) else { throw CameraEngineError.processingFailed }
          if facts["profileName"] == nil, let id = facts["profileID"] as? String { facts["profileName"] = profileNames[id] }
          snapshot = (file, facts, image)
        } catch { try? self.fm.removeItem(at: cache) }
        let loaded = snapshot
        DispatchQueue.main.async {
          self.viewerOpening = false
          guard let (file, facts, image) = loaded, let presenter = self.presenter(),
                !presenter.isBeingDismissed, !presenter.isBeingPresented,
                presenter.viewIfLoaded?.window != nil else { completion(.failure(.processingFailed)); return }
          let viewer = CameraPhotoViewer(file: file, facts: facts, image: image, removePhoto: { callback in
            self.deleteViewedPhoto(facts, completion: callback)
          }, onClose: { deleted in
            // Viewer and share sheet have released their ownership before removal.
            self.queue.async { try? self.fm.removeItem(at: cache) }
            completion(.success(["deleted": deleted, "captureID": facts["captureID"] ?? ""]))
          })
          CameraOrientationSubscriber.viewingPhoto = true
          presenter.present(viewer, animated: !UIAccessibility.isReduceMotionEnabled)
        }
      }
    }
  }

  private func deleteViewedPhoto(_ facts: [String: Any], completion: @escaping (String?) -> Void) {
    let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    Self.authorize {
      self.queue.async {
        guard Self.canReadOwnPhotos, let assetID = facts["assetLocalIdentifier"] as? String, !assetID.isEmpty,
              let jobID = facts["jobID"] as? String, UUID(uuidString: jobID) != nil else {
          DispatchQueue.main.async { completion(zh ? "请允许访问这张系统相册照片后重试。照片和预览均已保留。" : "Allow access to this photo in Settings, then retry. The photo and preview are kept.") }; return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard assets.count == 1 else {
          DispatchQueue.main.async { completion(zh ? "无法访问对应的相册照片，它可能已被删除或不在允许访问的范围内。App 预览已保留。" : "The Photos asset is unavailable. It may have been deleted or excluded from allowed access. The app preview is kept.") }; return
        }
        PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(assets) }) { success, error in
          self.queue.async {
            guard success else {
              DispatchQueue.main.async { completion(error?.localizedDescription ?? (zh ? "系统未完成删除，照片已保留。" : "Deletion was not completed. The photo is kept.")) }; return
            }
            do {
              let marker = self.deletedURL(jobID)
              try self.fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
              var tombstone = facts
              tombstone["previewDeleted"] = true
              tombstone.removeValue(forKey: "fileUri"); tombstone.removeValue(forKey: "thumbnailUri")
              let data = try JSONSerialization.data(withJSONObject: tombstone)
              try data.write(to: marker, options: .atomic)
              let manifest = self.directory.deletingLastPathComponent().appendingPathComponent("Camera18Latest/latest.json")
              let current = (try? Data(contentsOf: manifest)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
              if current?["jobID"] as? String == jobID {
                // Keep its timestamp as a high-water mark: older recovered photos
                // must not become the newest photo after this explicit deletion.
                try data.write(to: manifest, options: .atomic)
              }
              if let uri = facts["fileUri"] as? String, let file = URL(string: uri), file.isFileURL { try? self.fm.removeItem(at: file) }
              DispatchQueue.main.async { completion(nil) }
            } catch {
              DispatchQueue.main.async { completion(zh ? "系统相册照片已删除，但本地预览清理失败，请重启后重试。" : "The photo was deleted from Photos, but local preview cleanup failed. Restart the app and try again.") }
            }
          }
        }
      }
    }
  }

  private func presenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var controller = scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let next = controller?.presentedViewController { controller = next }
    return controller
  }
  /// A single recovery sheet, accessible from the delivery pill and photo viewer.
  /// No automatic deletion of a sole original; removal is an explicit user choice.
  func showRecovery(completion: @escaping () -> Void) {
    queue.async {
      let state = self.stateValue()
      let pending = self.jobs()
      let archive = self.directory.deletingLastPathComponent().appendingPathComponent("Camera18Originals", isDirectory: true)
      let retained = (try? self.fm.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)) ?? []
      let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
      DispatchQueue.main.async {
        guard let presenter = self.presenter() else { completion(); return }
        let message = zh
          ? "正在完成：\(state["processing"] ?? 0) 张\n等待重试：\(state["waiting"] ?? 0) 张\n本地保留原图：\(state["originals"] ?? 0) 张"
          : "Finishing: \(state["processing"] ?? 0)\nWaiting to retry: \(state["waiting"] ?? 0)\nOriginals kept locally: \(state["originals"] ?? 0)"
        let sheet = UIAlertController(title: zh ? "照片状态" : "Photo status", message: message, preferredStyle: .actionSheet)
        if !pending.isEmpty {
          sheet.addAction(UIAlertAction(title: zh ? "重试完成照片" : "Retry finishing photos", style: .default) { _ in self.resume() })
        }
        if !Self.canReadOwnPhotos {
          sheet.addAction(UIAlertAction(title: zh ? "前往设置允许照片访问" : "Allow photo access in Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
          })
        }
        let stoppable = pending.filter { !$0.proxy && $0.lastError != nil }
        if !stoppable.isEmpty {
          sheet.addAction(UIAlertAction(title: zh ? "保留原图，结束等待…" : "Keep originals and stop waiting…", style: .default) { [weak sheet] _ in
            guard let sheet else { return }
            let confirm = UIAlertController(title: zh ? "结束这些照片的风格处理？" : "Stop styling these photos?",
              message: zh ? "原始照片会保留在本机，可在照片状态中导出。未完成风格的试拍名额将释放。" : "Originals stay on this device for export. Unfinished trial reservations are released.", preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: zh ? "取消" : "Cancel", style: .cancel))
            confirm.addAction(UIAlertAction(title: zh ? "保留原图并结束" : "Keep originals and stop", style: .default) { _ in
              self.queue.async {
                guard !self.active else { self.publishState(); return }
                try? self.fm.createDirectory(at: archive, withIntermediateDirectories: true)
                for job in stoppable {
                  let destination = archive.appendingPathComponent(job.id, isDirectory: true)
                  do {
                    var facts = (try? JSONSerialization.jsonObject(with: job.diagnosticsData)) as? [String: Any] ?? [:]
                    facts.merge(["jobID": job.id, "ok": false, "terminal": true, "retained": true,
                      "originalSaved": job.originalConfirmed == true, "errorCode": CameraEngineError.processingFailed.rawValue]) { _, new in new }
                    try self.fm.moveItem(at: self.folder(job.id), to: destination)
                    try self.persistOutcome(facts, id: job.id)
                    DispatchQueue.main.async { self.eventSink?(facts) }
                  } catch {
                    // A failed move or outcome write never deletes the retained source.
                  }
                }
                self.updateCapacity()
              }
            })
            sheet.dismiss(animated: true) { presenter.present(confirm, animated: true) }
          })
        }
        let exportable = pending.filter { !$0.proxy }.map { self.sourceURL($0) }
          + retained.map { $0.appendingPathComponent("source.data") }
        if !exportable.isEmpty {
          sheet.addAction(UIAlertAction(title: zh ? "导出保留的原图" : "Export retained originals", style: .default) { _ in
            self.queue.async {
              // Give shared files a truthful extension. Keep private originals untouched.
              let exportDirectory = self.directory.deletingLastPathComponent().appendingPathComponent("Camera18Export", isDirectory: true)
              try? self.fm.removeItem(at: exportDirectory)
              try? self.fm.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
              var urls: [URL] = []
              for source in exportable {
                guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(image) else { continue }
                let ext = (type as String) == "public.jpeg" ? "jpg" : "heic"
                let target = exportDirectory.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent).appendingPathExtension(ext)
                if (try? self.fm.copyItem(at: source, to: target)) != nil { urls.append(target) }
              }
              DispatchQueue.main.async {
                guard !urls.isEmpty, let current = self.presenter() else { return }
                let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = current.view
                current.present(activity, animated: true)
              }
            }
          })
        }
        if !retained.isEmpty {
          sheet.addAction(UIAlertAction(title: zh ? "清理本地保留的原图…" : "Remove locally retained originals…", style: .destructive) { [weak sheet] _ in
            guard let sheet else { return }
            let alert = UIAlertController(title: zh ? "删除本地原图？" : "Delete local originals?",
              message: zh ? "相册中的风格照片会保留。删除后将无法从这些本地文件恢复干净原图，请先导出。" : "Styled photos in Photos remain. These clean originals cannot be recovered after deletion. Export them first.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: zh ? "取消" : "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: zh ? "删除本地原图" : "Delete local originals", style: .destructive) { _ in
              self.queue.async { for file in retained { try? self.fm.removeItem(at: file) }; self.publishState() }
            })
            sheet.dismiss(animated: true) { presenter.present(alert, animated: true) }
          })
        }
        sheet.addAction(UIAlertAction(title: zh ? "关闭" : "Close", style: .cancel))
        sheet.popoverPresentationController?.sourceView = presenter.view
        presenter.present(sheet, animated: true, completion: completion)
      }
    }
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
