import Foundation

/// Persist identity relative to Camera18Latest, never an installation's container UUID.
/// Legacy manifests stored absolute URLs; only their filename is needed to migrate.
enum CameraPhotoFiles {
  static func latestFile(in directory: URL, facts: [String: Any], fileManager: FileManager = .default) -> URL? {
    var names: [String] = []
    if let name = facts["fileName"] as? String { names.append(name) }
    if let uri = facts["fileUri"] as? String, let legacy = URL(string: uri), legacy.isFileURL,
       legacy.deletingLastPathComponent().lastPathComponent == "Camera18Latest" {
      names.append(legacy.lastPathComponent)
    }
    if let id = facts["jobID"] as? String, UUID(uuidString: id) != nil {
      names += ["heic", "heif", "jpg", "jpeg"].map { "\(id).\($0)" }
    }
    for name in names where !name.isEmpty && name == (name as NSString).lastPathComponent && name != "." && name != ".." {
      let file = directory.appendingPathComponent(name)
      if fileManager.fileExists(atPath: file.path) { return file }
    }
    return nil
  }
}
