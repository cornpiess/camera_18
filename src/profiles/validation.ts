import { HUE_BAND_NAMES, type ProfileDocument, type ProfileValidationResult } from './types';
type Obj = Record<string, unknown>;
const obj = (v: unknown): v is Obj => typeof v === 'object' && v !== null && !Array.isArray(v);

// Unknown keys are deliberately IGNORED (not rejected): the schema must stay forward-compatible
// so future calibration documents (new bands, new stages) import cleanly on older engines.
type ErrorSink = (message: string) => void;
const optNum = (v: Obj, key: string, p: string, e: ErrorSink, range?: [number, number]): void => {
  const value = v[key];
  if (value === undefined) return;
  if (typeof value !== 'number' || !Number.isFinite(value)) { e(`${p}.${key} must be a finite number`); return; }
  if (range && (value < range[0] || value > range[1])) e(`${p}.${key} must be between ${range[0]} and ${range[1]}`);
};
const nums = (v: unknown, keys: readonly string[], p: string, e: ErrorSink): v is Obj => {
  if (!obj(v)) { e(`${p} must be an object`); return false; }
  keys.forEach(k => { if (typeof v[k] !== 'number' || !Number.isFinite(v[k])) e(`${p}.${k} must be a finite number`); });
  return true;
};
const profile = (v: unknown, i: number, e: string[]): void => {
  const p = `profiles[${i}]`;
  pushProfileErrors(v, (message) => e.push(`${p}.${message}`));
};

// Core per-profile checks; messages are relative to the profile root so both the
// document validator and the standalone single-profile validator can use them.
const pushProfileErrors = (v: unknown, e: (message: string) => void): void => {
  if (!obj(v)) { e('must be an object'); return; }
  for (const k of ['id','name'] as const) if (typeof v[k] !== 'string' || v[k].trim() === '') e(`${k} must be a non-empty string`);
  if (v.displayName !== undefined && (typeof v.displayName !== 'string' || v.displayName.trim() === '')) e('displayName must be a non-empty string');
  if (v.developmentReference !== undefined && !obj(v.developmentReference)) e('developmentReference must be an object');
  if (v.passthrough !== undefined && typeof v.passthrough !== 'boolean') e('passthrough must be a boolean');
  if (v.recipe !== undefined) {
    if (!obj(v.recipe)) e('recipe must be an object');
    else {
      if (typeof v.recipe.version !== 'string' || v.recipe.version.trim() === '') e('recipe.version must be a non-empty string');
      if (!['approximation', 'candidate', 'measured', 'passthrough'].includes(v.recipe.status as string)) e('recipe.status is unsupported');
      if (!['camera18-srgb-ci-v1', 'camera18-srgb-ci-v2'].includes(v.recipe.colorContract as string)) e('recipe.colorContract is unsupported');
      if (v.recipe.datasetId !== undefined && (typeof v.recipe.datasetId !== 'string' || v.recipe.datasetId.trim() === '')) e('recipe.datasetId must be a non-empty string');
      if (v.recipe.status === 'measured' && typeof v.recipe.datasetId !== 'string') e('measured recipes require recipe.datasetId');
      if (v.recipe.status === 'passthrough' && v.passthrough !== true) e('passthrough recipe requires passthrough=true');
    }
  }
  const unified = obj(v.recipe) && v.recipe.colorContract === 'camera18-srgb-ci-v2';
  if (v.adaptive !== undefined) {
    if (!unified) e('adaptive requires camera18-srgb-ci-v2');
    if (nums(v.adaptive, ['highlightProtection', 'shadowChromaProtection', 'skinProtection'], 'adaptive', e)) {
      optNum(v.adaptive, 'highlightProtection', 'adaptive', e, [0, 1]);
      optNum(v.adaptive, 'shadowChromaProtection', 'adaptive', e, [0, 0.3]);
      optNum(v.adaptive, 'skinProtection', 'adaptive', e, [0, 0.3]);
    }
  }
  // Optional: the passthrough ORIG profile legitimately has no aperture identity.
  if (v.aperture !== undefined && nums(v.aperture, ['preferred'], 'aperture', e)) {
    if (typeof v.aperture.preferred === 'number' && v.aperture.preferred <= 0) e('aperture.preferred must be greater than zero');
    optNum(v.aperture, 'starZone', 'aperture', e, [1, 32]);
  }
  if (!obj(v.ui)) e('ui must be an object'); else {
    for (const k of ['shortName','accent','dialStyle']) if (typeof v.ui[k] !== 'string' || v.ui[k] === '') e(`ui.${k} must be a non-empty string`);
    for (const k of ['personality','labelStyle','markerStyle'] as const) {
      if (v.ui[k] !== undefined && (typeof v.ui[k] !== 'string' || v.ui[k] === '')) e(`ui.${k} must be a non-empty string`);
    }
    optNum(v.ui, 'glassTintStrength', 'ui', e, [0, 1]);
    if (v.ui.look !== undefined) {
      if (!obj(v.ui.look)) e('ui.look must be an object');
      else for (const lang of ['en', 'zh']) {
        const copy = v.ui.look[lang];
        if (!obj(copy)) e(`ui.look.${lang} must be an object`);
        else for (const key of ['title', 'description', 'subject']) {
          if (typeof copy[key] !== 'string' || copy[key].trim() === '') e(`ui.look.${lang}.${key} must be a non-empty string`);
        }
      }
    }
  }
  if (v.raw !== undefined) nums(v.raw, ['sharpness','detail','localToneMap','luminanceNoiseReduction','colorNoiseReduction'], 'raw', e);
  if (!obj(v.tone)) e('tone must be an object'); else {
    const tone = v.tone;
    ['exposure','contrast','blackPoint'].forEach(k => { if (typeof tone[k] !== 'number' || !Number.isFinite(tone[k])) e(`tone.${k} must be a finite number`); });
    optNum(tone, 'exposure', 'tone', e, [-5, 5]);
    optNum(tone, 'contrast', 'tone', e, [0, 4]);
    optNum(tone, 'blackPoint', 'tone', e, [0, 0.95]);
    optNum(tone, 'exposureBias', 'tone', e, [-5, 5]);
    const curve = tone.curve;
    if (!Array.isArray(curve) || curve.length !== 5) e('tone.curve must contain exactly five [x, y] points (the native tone-curve renderer requires exactly five)');
    else {
      if (Array.isArray(curve[0]) && curve[0][0] !== 0) e('tone.curve[0][0] must be 0 so the curve starts at black');
      if (Array.isArray(curve[4]) && curve[4][0] !== 1) e('tone.curve[4][0] must be 1 so the curve ends at white');
      let last = -Infinity;
      let lastY = -Infinity;
      curve.forEach((point, j) => {
        if (!Array.isArray(point) || point.length !== 2 || point.some(n => typeof n !== 'number' || !Number.isFinite(n))) { e(`tone.curve[${j}] must be a finite [x, y] tuple`); return; }
        const x = point[0] as number;
        const y = point[1] as number;
        if (x < 0 || x > 1 || y < 0 || y > 1) e(`tone.curve[${j}] values must be between 0 and 1`);
        if (x <= last) e(`tone.curve[${j}][0] must increase strictly`);
        if (unified && y < lastY) e(`tone.curve[${j}][1] must not decrease in v2`);
        last = x; lastY = y;
      });
    }
  }
  if (!obj(v.color)) e('color must be an object'); else {
    const color = v.color;
    ['saturation','temperature','tint'].forEach(k => { if (typeof color[k] !== 'number' || !Number.isFinite(color[k])) e(`color.${k} must be a finite number`); });
    optNum(color, 'saturation', 'color', e, [0, 4]);
    optNum(color, 'temperature', 'color', e, [-4500, 5500]);
    optNum(color, 'tint', 'color', e, [-200, 200]);
    if (color.lut !== undefined && color.lut !== null && typeof color.lut !== 'string') e('color.lut must be a string or null');
    optNum(color, 'lutIntensity', 'color', e, [0, 1]);
    if (color.splitTone !== undefined) {
      if (!obj(color.splitTone)) e('color.splitTone must be an object');
      else for (const key of ['shadows', 'highlights']) {
        const offset = color.splitTone[key];
        if (!Array.isArray(offset) || offset.length !== 3 || offset.some(n => typeof n !== 'number' || !Number.isFinite(n) || Math.abs(n) > 0.12)) {
          e(`color.splitTone.${key} must contain three finite RGB offsets between -0.12 and 0.12`);
        }
      }
    }
    if (!obj(color.hueBands)) e('color.hueBands must be an object'); else {
      const hueBands = color.hueBands;
      HUE_BAND_NAMES.forEach(b => {
        const band = hueBands[b];
        if (nums(band, ['hue','saturation','luminance'], `color.hueBands.${b}`, e)) {
          optNum(band, 'hue', `color.hueBands.${b}`, e, [-180, 180]);
          optNum(band, 'saturation', `color.hueBands.${b}`, e, [0, 4]);
          optNum(band, 'luminance', `color.hueBands.${b}`, e, [0, 4]);
          if (unified && band.luminance !== 1) e(`color.hueBands.${b}.luminance must be 1 in v2; use tone for luminance`);
        }
      });
    }
  }
  if (!obj(v.texture)) e('texture must be an object'); else {
    nums(v.texture.grain, ['amount','size'], 'texture.grain', e);
    nums(v.texture.vignette, ['amount','radius'], 'texture.vignette', e);
    if (obj(v.texture.grain)) {
      optNum(v.texture.grain, 'amount', 'texture.grain', e, [0, 0.2]);
      // Legacy zero-grain recipes used size=0.3. The native lower clamp is harmless
      // while disabled; reject silently-clamped sizes when grain actually executes.
      optNum(v.texture.grain, 'size', 'texture.grain', e, [v.recipe !== undefined && (v.texture.grain.amount as number) > 0 ? 0.5 : 0, 3]);
    }
    if (obj(v.texture.vignette)) {
      optNum(v.texture.vignette, 'amount', 'texture.vignette', e, [0, 0.5]);
      optNum(v.texture.vignette, 'radius', 'texture.vignette', e, [0.3, 1.5]);
    }
    if (v.texture.halation !== undefined) nums(v.texture.halation, ['amount','radius'], 'texture.halation', e);
    if (v.texture.detail !== undefined) {
      if (!unified) e('texture.detail requires camera18-srgb-ci-v2');
      if (nums(v.texture.detail, ['edgeSoftness', 'radius'], 'texture.detail', e)) {
        optNum(v.texture.detail, 'edgeSoftness', 'texture.detail', e, [0, 0.35]);
        optNum(v.texture.detail, 'radius', 'texture.detail', e, [0.25, 1.5]);
      }
    }
    optNum(v.texture, 'deharsh', 'texture', e, [0, 1]);
    if (v.texture.starburst !== undefined) {
      nums(v.texture.starburst, ['threshold','strength','length','rays'], 'texture.starburst', e);
    }
  }
};

/**
 * Validate a single profile object. Error messages are relative to the profile root
 * (e.g. "tone.curve must contain exactly five [x, y] points"), so callers that handle
 * one standalone profile (per-camera import) can surface them directly.
 */
export function validateProfileEntry(value: unknown): string[] {
  const errors: string[] = [];
  pushProfileErrors(value, (message) => errors.push(message));
  return errors;
}
export function validateProfileEntryDocument(value: unknown): ProfileValidationResult {
  const errors = validateProfileEntry(value);
  return errors.length ? { success: false, errors } : { success: true, document: { schemaVersion: 1, profiles: [stripDevelopmentMetadata({ profiles: [value] }).profiles[0]!] } };
}
export function validateProfileDocument(value: unknown): ProfileValidationResult {
  const errors: string[] = [];
  if (!obj(value)) return { success: false, errors: ['Document root must be an object'] };
  if (value.schemaVersion !== 1) errors.push('document.schemaVersion must equal 1');
  if (!Array.isArray(value.profiles) || value.profiles.length === 0) errors.push('document.profiles must be a non-empty array'); else {
    value.profiles.forEach((v,i) => profile(v,i,errors));
    const ids = value.profiles.filter(obj).map(v => v.id).filter((id): id is string => typeof id === 'string');
    ids.forEach((id,i) => { if (ids.indexOf(id) !== i) errors.push(`profiles contains duplicate id "${id}"`); });
  }
  return errors.length ? { success: false, errors } : { success: true, document: stripDevelopmentMetadata(value) };
}

/**
 * DEV/PROD separation: developmentReference never leaves the validator. Bundled and imported
 * documents may carry it for calibration work, but the runtime state (and therefore the UI and
 * any exported-from-memory JSON) only ever sees the production identity.
 */
function stripDevelopmentMetadata(value: Obj): ProfileDocument {
  return {
    ...value,
    profiles: (value.profiles as unknown[]).map((entry) => {
      if (!obj(entry) || entry.developmentReference === undefined) return entry;
      const { developmentReference: _dev, ...rest } = entry;
      return rest;
    }),
  } as unknown as ProfileDocument;
}
export function parseProfileDocument(text: string): ProfileValidationResult {
  try { return validateProfileDocument(JSON.parse(text) as unknown); }
  catch (error: unknown) { return { success: false, errors: [`Invalid JSON: ${error instanceof Error ? error.message : String(error)}`] }; }
}
export function assertProfileDocument(value: unknown): asserts value is ProfileDocument {
  const result = validateProfileDocument(value); if (!result.success) throw new Error(result.errors.join('\n'));
}
export type { CameraProfile, ProfileDocument } from './types';
