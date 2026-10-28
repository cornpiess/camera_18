// Execute the production receipt matcher, including out-of-order / duplicate recovery.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');
const vm = require('node:vm');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/camera/captureReceipts.ts', 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: exportsObject });
const take = exportsObject.takeCaptureReservation;
const first = { captureID: 'one', profile: 'a' };
const second = { captureID: 'two', profile: 'b' };
const queue = [first, second];
assert.equal(take(queue, 'two'), second); // Later exposure finishes first.
assert.equal(queue.length, 1);
assert.equal(take(queue, 'recovered-from-last-session'), undefined);
assert.equal(take(queue, 'two'), undefined); // Duplicate completion cannot debit twice.
assert.equal(take(queue, undefined), undefined); // Hardware/free event owns no reservation.
assert.equal(take(queue, 'one'), first);
assert.equal(queue.length, 0);
const { buildFocalStops } = (() => {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync('src/camera/focalLadder.ts', 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS },
  }).outputText, { exports });
  return exports;
})();
assert.equal(buildFocalStops({ ultraWide: false, tele: false }).length, 3);
assert.equal(buildFocalStops({ ultraWide: true, tele: true, teleZoom: 10 }).at(-1).mm, 130);
console.log('Capture receipts: out-of-order, duplicate, recovery, free/hardware events PASS; focal inventory PASS.');
const { settleCaptureReservation, canRequestCapture } = exportsObject;
const resumable = [{ captureID: 'pending-style' }];
assert.equal(settleCaptureReservation(resumable, { captureID: 'pending-style', terminal: false }), undefined);
assert.equal(resumable.length, 1);
assert.equal(settleCaptureReservation(resumable, { captureID: 'pending-style', terminal: true }).captureID, 'pending-style');
assert.equal(settleCaptureReservation(resumable, { captureID: 'pending-style', terminal: true }), undefined);
for (const ready of [false, true]) for (const optics of [false, true]) for (const exposing of [false, true]) {
  assert.equal(canRequestCapture({ ready }, optics, exposing), ready && !optics && !exposing);
}
console.log('Retained -> resumed -> duplicate result settlement PASS; shutter readiness matrix PASS.');

const { captureRecoveryAction } = exportsObject;
// Ordinary exposure, rendering and aperture moves have no status overlay. A
// previous failed photo alone may offer recovery, but never changes shutter gates.
for (const reason of ['ready', 'optics', 'exposing', 'processing']) {
  for (const processing of [0, 1, 8]) for (const paused of [false, true]) {
    assert.equal(captureRecoveryAction({ reason }, { waiting: 0, processing, paused }), null);
    assert.equal(captureRecoveryAction({ reason }, { waiting: 2, processing, paused }), 'photos');
  }
}
assert.equal(captureRecoveryAction({ reason: 'unavailable' }, { waiting: 0 }), 'camera');
assert.equal(captureRecoveryAction({ reason: 'aperture' }, { waiting: 0 }), 'aperture');
assert.equal(captureRecoveryAction({ reason: 'aperture' }, { waiting: 3 }), 'aperture');
assert.equal(captureRecoveryAction({ reason: 'ready' }, { waiting: 0 }), null); // Retry succeeded.
assert.equal(canRequestCapture({ ready: true }, false, false), true); // Old failures do not gate new photos.
console.log('Quiet normal capture/aperture UI; actionable failure and recovery states PASS.');
