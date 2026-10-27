// Offline authoring only. Fits a small, regularized quadratic RGB residual, then
// samples it into a normal .cube. No model/runtime dependency enters the iOS app.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { s2l, linearToOKLab, oklabDist } = require('./tone-audit');

const CONTRACT = 'camera18-srgb-ci-v1';
const clamp = x => Math.max(0, Math.min(1, x));
const check = (ok, message) => { if (!ok) throw new Error(message); };
const nonempty = value => typeof value === 'string' && value.trim().length > 0;
const rgb = value => Array.isArray(value) && value.length === 3 && value.every(x => typeof x === 'number' && Number.isFinite(x) && x >= 0 && x <= 1);
const lab = value => linearToOKLab(...value.map(s2l));
const delta = (a, b) => oklabDist(lab(a), lab(b));
const features = ([r, g, b]) => [1, r, g, b, r*r, g*g, b*b, r*g, r*b, g*b];

function validateDataset(dataset) {
  check(dataset?.schemaVersion === 1, 'dataset.schemaVersion must be 1');
  check(nonempty(dataset.id), 'dataset.id is required');
  check(dataset.colorSpace === 'srgb-encoded', 'Samples must be explicitly converted to encoded sRGB, not P3, linear RGB or untagged values');
  check(['paired-camera', 'synthetic'].includes(dataset.evidence), 'evidence must be paired-camera or synthetic');
  for (const key of ['source', 'target']) {
    check(dataset[key] && ['device', 'settings'].every(field => nonempty(dataset[key][field])), `${key}.device and ${key}.settings are required`);
  }
  check(Array.isArray(dataset.scenes) && dataset.scenes.length >= 3, 'Need at least two training scenes and one independent validation scene');
  const scenes = new Set(), captures = new Set(), splits = { train: [], validation: [] };
  for (const scene of dataset.scenes) {
    check(nonempty(scene.id) && !scenes.has(scene.id), 'Scene IDs must be nonempty and unique');
    scenes.add(scene.id);
    check(['train', 'validation'].includes(scene.split), `${scene.id}: split must be train or validation`);
    check(nonempty(scene.lighting), `${scene.id}: lighting must be recorded`);
    check(Array.isArray(scene.captureIds) && scene.captureIds.length >= 2, `${scene.id}: record the source/target capture identifiers`);
    for (const id of scene.captureIds) {
      check(nonempty(id) && !captures.has(id), `Capture reused across scenes: ${id}`);
      captures.add(id);
    }
    check(Array.isArray(scene.samples) && scene.samples.length > 0, `${scene.id}: samples are required`);
    for (const sample of scene.samples) {
      check(rgb(sample.source) && rgb(sample.target), `${scene.id}: finite RGB triples in 0...1 required`);
      check(nonempty(sample.category), `${scene.id}: each patch needs a category (skin, gray, foliage, etc.)`);
      splits[scene.split].push({ ...sample, sceneId: scene.id });
    }
  }
  check(dataset.scenes.filter(s => s.split === 'train').length >= 2, 'Need at least two training scenes');
  check(splits.train.length >= 24 && splits.validation.length >= 12, 'Need at least 24 training and 12 validation patches');
  // Detect exact pair leakage even if the capture/scene identifiers were renamed.
  const trainPairs = new Set(splits.train.map(s => JSON.stringify([s.source, s.target])));
  check(!splits.validation.some(s => trainPairs.has(JSON.stringify([s.source, s.target]))), 'Identical patch pairs occur in train and validation');
  check(new Set(splits.train.map(s => JSON.stringify(s.source))).size >= 20, 'Training patches lack independent input colors');
  for (let channel = 0; channel < 3; channel++) {
    const values = splits.train.map(s => s.source[channel]);
    check(Math.max(...values) - Math.min(...values) >= 0.4, 'Training colors must cover a useful RGB range');
  }
  return splits;
}

function solve(matrix, vector) {
  const a = matrix.map((row, i) => [...row, vector[i]]), n = vector.length;
  for (let i = 0; i < n; i++) {
    let pivot = i;
    for (let j = i + 1; j < n; j++) if (Math.abs(a[j][i]) > Math.abs(a[pivot][i])) pivot = j;
    [a[i], a[pivot]] = [a[pivot], a[i]];
    check(Math.abs(a[i][i]) > 1e-12, 'Ill-conditioned dataset');
    const scale = a[i][i];
    for (let k = i; k <= n; k++) a[i][k] /= scale;
    for (let j = 0; j < n; j++) if (j !== i) {
      const factor = a[j][i];
      for (let k = i; k <= n; k++) a[j][k] -= factor * a[i][k];
    }
  }
  return a.map(row => row[n]);
}

function fit(samples, ridge = 0.01) {
  const n = 10, matrix = Array.from({ length: n }, () => Array(n).fill(0));
  const vectors = Array.from({ length: 3 }, () => Array(n).fill(0));
  // Equal scene influence: a scene with many chart patches cannot dominate a portrait.
  const counts = new Map();
  for (const sample of samples) counts.set(sample.sceneId, (counts.get(sample.sceneId) ?? 0) + 1);
  for (const sample of samples) {
    const f = features(sample.source), weight = 1 / counts.get(sample.sceneId);
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) matrix[i][j] += weight * f[i] * f[j];
      for (let ch = 0; ch < 3; ch++) vectors[ch][i] += weight * f[i] * (sample.target[ch] - sample.source[ch]);
    }
  }
  for (let i = 0; i < n; i++) matrix[i][i] += ridge * (i >= 4 ? 4 : 1);
  const coefficients = vectors.map(vector => solve(matrix, vector));
  const predict = input => {
    const f = features(input);
    return input.map((v, ch) => clamp(v + coefficients[ch].reduce((sum, c, i) => sum + c * f[i], 0)));
  };
  return { coefficients, predict };
}

function makeCube(predict, dim = 33) {
  const values = [];
  for (let b = 0; b < dim; b++) for (let g = 0; g < dim; g++) for (let r = 0; r < dim; r++) {
    values.push(predict([r/(dim-1), g/(dim-1), b/(dim-1)]));
  }
  return { dim, values };
}

function sampleCube(cube, input) {
  const { dim, values } = cube;
  const at = input.map(x => clamp(x) * (dim - 1));
  const lo = at.map(x => Math.min(dim - 2, Math.floor(x))), f = at.map((x, i) => x - lo[i]);
  const out = [0, 0, 0];
  for (let b = 0; b < 2; b++) for (let g = 0; g < 2; g++) for (let r = 0; r < 2; r++) {
    const value = values[(lo[2]+b)*dim*dim+(lo[1]+g)*dim+lo[0]+r];
    const w = (r ? f[0] : 1-f[0]) * (g ? f[1] : 1-f[1]) * (b ? f[2] : 1-f[2]);
    for (let ch = 0; ch < 3; ch++) out[ch] += w * value[ch];
  }
  return out;
}

function metrics(samples, outputs) {
  const errors = samples.map((s, i) => delta(outputs[i], s.target)).sort((a, b) => a-b);
  const baseline = samples.map(s => delta(s.source, s.target));
  const mean = values => values.reduce((a, b) => a+b, 0) / values.length;
  const byCategory = {};
  for (const category of new Set(samples.map(s => s.category))) {
    const indices = samples.flatMap((s, i) => s.category === category ? [i] : []);
    byCategory[category] = {
      count: indices.length,
      meanOKLabDistance: mean(indices.map(i => delta(outputs[i], samples[i].target))),
      baselineMeanOKLabDistance: mean(indices.map(i => delta(samples[i].source, samples[i].target))),
    };
  }
  const byScene = {};
  for (const sceneId of new Set(samples.map(s => s.sceneId))) {
    const indices = samples.flatMap((s, i) => s.sceneId === sceneId ? [i] : []);
    byScene[sceneId] = {
      count: indices.length,
      meanOKLabDistance: mean(indices.map(i => delta(outputs[i], samples[i].target))),
      baselineMeanOKLabDistance: mean(indices.map(i => delta(samples[i].source, samples[i].target))),
    };
  }
  return { count: samples.length, meanOKLabDistance: mean(errors), p95OKLabDistance: errors[Math.ceil(errors.length*0.95)-1],
    maxOKLabDistance: errors.at(-1), baselineMeanOKLabDistance: mean(baseline), byCategory, byScene,
    clippedChannelFraction: outputs.flat().filter(x => x <= 0 || x >= 1).length / (outputs.length*3) };
}

function candidate(dataset, id, outputDirectory) {
  const split = validateDataset(dataset);
  check(/^[a-z0-9_]+$/.test(id), 'Profile ID must contain only lowercase letters, digits and underscores');
  const bundled = JSON.parse(fs.readFileSync(path.join(__dirname, '../assets/camera-profiles.json'), 'utf8'));
  const base = bundled.profiles.find(p => p.id === id);
  check(base && !base.passthrough, 'Choose an existing styled profile; ORIG cannot be fitted');
  const model = fit(split.train), cube = makeCube(model.predict);
  const predict = value => sampleCube(cube, value);
  const report = {
    datasetId: dataset.id, evidence: dataset.evidence, colorContract: CONTRACT,
    datasetSHA256: crypto.createHash('sha256').update(JSON.stringify(dataset)).digest('hex'),
    method: 'scene-weighted quadratic residual, ridge=0.01, 33^3 trilinear evaluation',
    metric: 'Euclidean OKLab distance ×100; not CIEDE2000',
    train: metrics(split.train, split.train.map(s => predict(s.source))),
    validation: metrics(split.validation, split.validation.map(s => predict(s.source))),
    nativeValidation: 'pending', status: 'candidate', coefficients: model.coefficients,
  };
  // A fit is NEVER automatically promoted to measured or copied into production.
  const profile = structuredClone(base);
  const lut = `${id}-candidate`;
  profile.recipe = { version: `candidate-${report.datasetSHA256.slice(0,12)}`, status: 'candidate', colorContract: CONTRACT, datasetId: dataset.id };
  profile.color = { lut, lutIntensity: 1, temperature: 0, tint: 0, saturation: 1,
    hueBands: Object.fromEntries(['red','orange','yellow','green','cyan','blue','magenta'].map(name => [name, { hue: 0, saturation: 1, luminance: 1 }])) };
  profile.tone = { exposure: 0, contrast: 1, blackPoint: 0, curve: [[0,0],[0.25,0.25],[0.5,0.5],[0.75,0.75],[1,1]] };
  profile.texture = { grain: { amount: 0, size: 1 }, vignette: { amount: 0, radius: 0.75 }, deharsh: 0 };
  profile.developmentReference = { note: `Candidate from ${dataset.id}; ${dataset.evidence}; native verification required.` };
  fs.mkdirSync(outputDirectory, { recursive: true });
  check(fs.readdirSync(outputDirectory).length === 0, 'EEXIST: candidate output directory must be empty');
  const write = (name, value) => fs.writeFileSync(path.join(outputDirectory, name), JSON.stringify(value, null, 2)+'\n', { flag: 'wx' });
  const cubeText = `TITLE "Camera18 calibration candidate"\n# ${CONTRACT}; encoded sRGB authoring; verify with native probes before promotion.\nLUT_3D_SIZE 33\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n`
    + cube.values.map(row => row.map(v => v.toFixed(8)).join(' ')).join('\n')+'\n';
  fs.writeFileSync(path.join(outputDirectory, `${lut}.cube`), cubeText, { flag: 'wx' });
  write('profile.json', profile); write('report.json', report);
  write('probes.json', [...split.train, ...split.validation].map(s => s.source));
  return report;
}

function evaluateNative(dataset, native) {
  const split = validateDataset(dataset), all = [...split.train, ...split.validation];
  check(native?.colorContract === CONTRACT && native.rendererVersion === 4 && native.mode === 'final', 'Need final-mode native renderer v4 output for this color contract');
  check(Array.isArray(native.input) && Array.isArray(native.output) && native.input.length === all.length && native.output.length === all.length, 'Native probe counts do not match');
  for (let i = 0; i < all.length; i++) {
    check(rgb(native.input[i]) && native.input[i].every((v, ch) => Math.abs(v-all[i].source[ch]) < 1e-7), 'Native input order/data do not match this dataset');
    check(rgb(native.output[i]), 'Native output is not finite in-gamut RGB');
  }
  return { datasetId: dataset.id, evidence: dataset.evidence, rendererVersion: native.rendererVersion,
    profileId: native.profileId ?? 'not recorded', recipeVersion: native.recipeVersion ?? 'not recorded', lut: native.lut ?? null,
    metric: 'Euclidean OKLab distance ×100; not CIEDE2000',
    train: metrics(split.train, native.output.slice(0,split.train.length)),
    validation: metrics(split.validation, native.output.slice(split.train.length)),
    status: 'native color measured; visual, preview/input and device performance acceptance still required' };
}

module.exports = { validateDataset, fit, makeCube, sampleCube, metrics, candidate, evaluateNative };
if (require.main === module) {
  try {
    const [command, input, idOrNative, directory] = process.argv.slice(2);
    check(input && idOrNative && ((command === 'fit' && directory) || command === 'evaluate'),
      'Usage: node scripts/calibrate-camera.js fit <dataset.json> <profile-id> <new-output-dir> | evaluate <dataset.json> <native-probes.json>');
    const dataset = JSON.parse(fs.readFileSync(input, 'utf8'));
    const report = command === 'fit' ? candidate(dataset, idOrNative, directory) : evaluateNative(dataset, JSON.parse(fs.readFileSync(idOrNative, 'utf8')));
    console.log(JSON.stringify(report, null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
