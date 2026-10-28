// Meaningful synthetic checks for the authoring workflow, never camera-accuracy evidence.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const ts = require('typescript');
const { validateDataset, fit, makeCube, sampleCube, candidate, evaluateNative } = require('./calibrate-camera');

function dataset() {
  let state = 17;
  const random = () => { state = (Math.imul(state, 1664525)+1013904223) >>> 0; return state/4294967296; };
  return { schemaVersion: 1, id: 'synthetic-workflow-check', evidence: 'synthetic', colorSpace: 'srgb-encoded',
    source: { device: 'synthetic', settings: 'generated RGB; not camera measurements' },
    target: { device: 'synthetic', settings: 'known smooth mapping' },
    scenes: ['train','train','validation'].map((split, scene) => ({
      id: `scene-${scene}`, split, lighting: 'synthetic', captureIds: [`source-${scene}`, `target-${scene}`],
      samples: Array.from({ length: 24 }, () => {
        const source = [random(), random(), random()].map(v => .05+v*.9);
        const [r,g,b] = source;
        return { source, target: [.94*r+.02*g+.01, .96*g+.01*b+.01, .93*b+.02*r+.01], category: 'synthetic' };
      }),
    })) };
}

const data = dataset(), split = validateDataset(data);
const identity = fit(split.train.map(s => ({ ...s, target: s.source })));
for (const input of [[0,0,0],[1,1,1],[.12,.45,.87]]) {
  assert(identity.predict(input).every((v,i) => Math.abs(v-input[i]) < 1e-9));
}
const model = fit(split.train), cube = makeCube(model.predict);
for (const input of [[0,0,0],[1,1,1],[.12,.45,.87]]) {
  assert(sampleCube(cube,input).every((v,i) => Math.abs(v-model.predict(input)[i]) < .0001), 'cube ordering/interpolation');
}
const directory = fs.mkdtempSync(path.join(os.tmpdir(),'camera18-calibration-'));
try {
  const report = candidate(data, 'ricoh_negative', directory);
  assert(report.validation.meanOKLabDistance < report.validation.baselineMeanOKLabDistance * .3, 'fit must generalize to independent scenes');
  assert.equal(report.nativeValidation,'pending');
  const profile = JSON.parse(fs.readFileSync(path.join(directory,'profile.json')));
  assert.equal(profile.recipe.status,'candidate');
  assert.equal(profile.texture.grain.amount,0);
  assert.equal(profile.color.lutIntensity,1);
  // Runtime validator + diagnostic functions, not a duplicate schema implementation.
  const previous = require.extensions['.ts'];
  require.extensions['.ts'] = (module, filename) => module._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  }).outputText, filename);
  try {
    const { validateProfileDocument } = require('../src/profiles/validation.ts');
    const { renderedFingerprint } = require('../src/profiles/diagnostics.ts');
    assert.equal(validateProfileDocument({schemaVersion:1,profiles:[profile]}).success,true);
    const metadata = structuredClone(profile); metadata.name='UI rename'; metadata.recipe.version='another';
    assert.equal(renderedFingerprint(profile),renderedFingerprint(metadata));
    metadata.color.lutIntensity=.5;
    assert.notEqual(renderedFingerprint(profile),renderedFingerprint(metadata));
    const legacy=structuredClone(profile); delete legacy.recipe;
    legacy.raw={sharpness:.4,detail:.5,localToneMap:0,luminanceNoiseReduction:.1,colorNoiseReduction:.1};
    legacy.texture.halation={amount:0,radius:.2};
    legacy.texture.grain={amount:.02,size:.3};
    assert.equal(validateProfileDocument({schemaVersion:1,profiles:[legacy]}).success,true);
    const bad=structuredClone(profile); bad.recipe.colorContract='unknown';
    assert.equal(validateProfileDocument({schemaVersion:1,profiles:[bad]}).success,false);
    bad.recipe=profile.recipe;bad.texture.grain.amount=.4;
    assert.equal(validateProfileDocument({schemaVersion:1,profiles:[bad]}).success,false);
  } finally { if(previous)require.extensions['.ts']=previous;else delete require.extensions['.ts']; }
  assert.throws(()=>candidate(data,'ricoh_negative',directory),/EEXIST/,'do not overwrite existing candidates');
  const all=[...split.train,...split.validation];
  const native={colorContract:'camera18-srgb-ci-v1',rendererVersion:4,mode:'final',input:all.map(s=>s.source),output:all.map(s=>s.target)};
  assert.equal(evaluateNative(data,native).validation.meanOKLabDistance,0);
  assert.equal(evaluateNative(data,{...native, rendererVersion:5}).validation.meanOKLabDistance,0);
  assert.equal(evaluateNative(data,{...native, rendererVersion:5, colorContract:'camera18-srgb-ci-v2'}).validation.meanOKLabDistance,0);
  assert.throws(()=>evaluateNative(data,{...native,colorContract:'camera18-srgb-ci-v2'}),/compatible/);
  const mismatch=structuredClone(native);mismatch.input.reverse();
  assert.throws(()=>evaluateNative(data,mismatch),/order\/data/);
  const leaked=structuredClone(data);leaked.scenes[2].samples[0]=leaked.scenes[0].samples[0];
  assert.throws(()=>validateDataset(leaked),/Identical patch pairs/);
  const reused=structuredClone(data);reused.scenes[2].captureIds[0]=reused.scenes[0].captureIds[0];
  assert.throws(()=>validateDataset(reused),/Capture reused/);
  const bad=structuredClone(data);bad.scenes[0].samples[0].source[0]=true;
  assert.throws(()=>validateDataset(bad),/finite RGB/);
  const oneScene=structuredClone(data);oneScene.scenes[1].split='validation';
  assert.throws(()=>validateDataset(oneScene),/two training scenes/);
  console.log(`Calibration checks passed: independent-scene fit, identity, LUT interpolation, runtime import, candidate safety, leakage rejection, native-result matching. Synthetic validation distance=${report.validation.meanOKLabDistance.toFixed(3)} (not camera accuracy).`);
} finally { fs.rmSync(directory,{recursive:true,force:true}); }
