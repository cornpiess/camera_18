// Production schema/diagnostic checks plus CPU color guardrails. Core Image spatial
// pixels and performance are tested by native-calibration self-test on macOS.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');
const previous = require.extensions['.ts'];
require.extensions['.ts'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file,'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
}).outputText,file);
const {validateProfileDocument} = require('../src/profiles/validation.ts');
const {renderedFingerprint} = require('../src/profiles/diagnostics.ts');
if(previous)require.extensions['.ts']=previous;else delete require.extensions['.ts'];
const {applyPipeline,applyTone} = require('./tone-audit');
const doc = JSON.parse(fs.readFileSync('assets/camera-profiles.json','utf8'));
assert(validateProfileDocument(doc).success);
for(const [property,field,value] of [
  ['adaptive','skinProtection',.31],['adaptive','highlightProtection',NaN],
  ['adaptive','shadowChromaProtection',true],['detail','edgeSoftness',-.01],['detail','radius',0],
]){
  const bad=structuredClone(doc);
  const target=property==='detail'?bad.profiles[0].texture.detail:bad.profiles[0].adaptive;
  target[field]=value;
  assert(!validateProfileDocument(bad).success, `${property}.${field}: invalid input accepted`);
}
const legacy=structuredClone(doc);
for(const p of legacy.profiles){delete p.recipe;delete p.adaptive;delete p.texture.detail;}
assert(validateProfileDocument(legacy).success, 'Unversioned overrides remain importable');
const inactive=structuredClone(doc);inactive.profiles[0].recipe.colorContract='camera18-srgb-ci-v1';
assert(!validateProfileDocument(inactive).success, 'New controls must not silently do nothing on a legacy contract');
for(const mutate of [
 p=>{p.tone.curve[2][1]=0.05;},
 p=>{p.color.hueBands.red.luminance=1.1;},
]){
 const bad=structuredClone(doc);mutate(bad.profiles[0]);assert(!validateProfileDocument(bad).success);
}
const base=doc.profiles[0], metadata=structuredClone(base);
metadata.name='Label only'; metadata.recipe.version='new-label';
assert.equal(renderedFingerprint(base),renderedFingerprint(metadata));
for(const change of [p=>p.adaptive.skinProtection=.25,p=>p.texture.detail.edgeSoftness=.3,p=>p.recipe.colorContract='camera18-srgb-ci-v1']){
 const next=structuredClone(base);change(next);
 assert.notEqual(renderedFingerprint(base),renderedFingerprint(next), 'Rendering changes must invalidate the diagnostic identity');
}
const y=rgb=>.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];
let maxLumaError=0;
for(const p of doc.profiles.filter(p=>!p.passthrough)){
 for(let r=0;r<=8;r++)for(let g=0;g<=8;g++)for(let b=0;b<=8;b++){
  const rgb=[r/8,g/8,b/8],out=applyPipeline(p,rgb);
  maxLumaError=Math.max(maxLumaError,Math.abs(y(out)-y(applyTone(p,rgb))));
  assert(out.every(Number.isFinite));
 }
 const neutral=[0,.1,.25,.5,.75,.9,1].map(v=>y(applyPipeline(p,[v,v,v])));
 assert(neutral.every((v,i)=>i===0||v>=neutral[i-1]), `${p.id}: reversed gray response`);
}
assert(maxLumaError<1e-8,'Tone and chroma responsibilities leaked in CPU reference');
console.log(`Unified rendering checks passed: v1/v2 imports, control bounds, diagnostic identity, gray monotonicity, color-only luma max error=${maxLumaError.toExponential(2)}. Native pixels remain separately required.`);
