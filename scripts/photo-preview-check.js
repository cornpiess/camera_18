const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');
const ts = require('typescript');

const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/camera/photoPreviewFailure.ts', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS },
}).outputText, { exports: exportsObject });
const message = exportsObject.photoPreviewFailureKey;
const failures = {
  ERR_PHOTO_PREVIEW_MISSING: 'photoPreviewMissing',
  ERR_PHOTO_PREVIEW_DECODE: 'photoPreviewDecode',
  ERR_PHOTO_PREVIEW_COPY: 'photoPreviewCopy',
  ERR_PHOTO_PREVIEW_READ: 'photoPreviewRead',
  ERR_PHOTO_READ_DENIED: 'photoPreviewPermission',
  ERR_NO_ACTIVE_VIEW: 'photoPreviewWindow',
  ERR_CAPTURE_BUSY: 'errCaptureBusy',
};
for (const [code, key] of Object.entries(failures)) assert.equal(message(code), key);
assert.equal(message('ERR_NATIVE_FAILURE'), 'photoUnavailable');
console.log('Viewer failure messages distinguish missing / decode / storage / Photos / permission / presenter / busy: PASS');

// Execute the actual Foundation production helper on hosts with Swift. No UIKit
// or iPhone is needed for the container-relocation regression. Linux hosts without
// Swift explicitly report the gap instead of running a JS imitation of the helper.
if (spawnSync('swift', ['--version'], { encoding: 'utf8' }).error) {
  console.log('SKIP: native file-path regression needs Swift (run this command on macOS).');
} else {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'camera18-preview-'));
  try {
    const test = fs.readFileSync('modules/camera-engine/ios/CameraPhotoFiles.swift', 'utf8') + `
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
defer { try? fm.removeItem(at: root) }
let current = root.appendingPathComponent("NEW/Camera18Latest", isDirectory: true)
let old = root.appendingPathComponent("OLD/Camera18Latest", isDirectory: true)
try fm.createDirectory(at: current, withIntermediateDirectories: true)
let id = UUID().uuidString
let photo = current.appendingPathComponent(id + ".heif")
try Data([1, 2, 3]).write(to: photo)
let legacy: [String: Any] = ["jobID": id, "fileUri": old.appendingPathComponent(photo.lastPathComponent).absoluteString]
assert(!fm.fileExists(atPath: URL(string: legacy["fileUri"] as! String)!.path))
assert(CameraPhotoFiles.latestFile(in: current, facts: legacy) == photo)
assert(CameraPhotoFiles.latestFile(in: current, facts: ["fileName": photo.lastPathComponent]) == photo)
assert(CameraPhotoFiles.latestFile(in: current, facts: ["jobID": id]) == photo)
assert(CameraPhotoFiles.latestFile(in: current, facts: ["fileName": "../escape.heic"]) == nil)
assert(CameraPhotoFiles.latestFile(in: current, facts: ["fileUri": "https://example.com/Camera18Latest/" + photo.lastPathComponent]) == nil)
assert(CameraPhotoFiles.latestFile(in: current, facts: ["fileUri": "file:///unrelated/" + photo.lastPathComponent]) == nil)
try fm.removeItem(at: photo)
assert(CameraPhotoFiles.latestFile(in: current, facts: legacy) == nil)
print("Production Swift: relocated container / legacy .heif / relative name / job identity / missing file / unsafe path: PASS")
`;
    const file = path.join(dir, 'main.swift');
    fs.writeFileSync(file, test);
    const result = spawnSync('swift', [file], { encoding: 'utf8', timeout: 60000 });
    assert.equal(result.status, 0, result.stderr || result.error?.message);
    process.stdout.write(result.stdout);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}
