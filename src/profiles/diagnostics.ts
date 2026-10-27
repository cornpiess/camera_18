import type { CameraProfile } from './types';

// A deterministic parameter identifier, not a security hash or rendered-image checksum.
// UI copy, recommendations and recipe labels do not participate.
export function renderedFingerprint(profile: CameraProfile): string {
  const canonical = (value: unknown): string => {
    if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
    if (value !== null && typeof value === 'object') {
      const record = value as Record<string, unknown>;
      return `{${Object.keys(record).sort().map(key => `${JSON.stringify(key)}:${canonical(record[key])}`).join(',')}}`;
    }
    return JSON.stringify(value) ?? 'null';
  };
  const payload = canonical({
    color: profile.color,
    tone: { exposure: profile.tone.exposure, contrast: profile.tone.contrast, blackPoint: profile.tone.blackPoint, curve: profile.tone.curve },
    texture: { grain: profile.texture.grain, vignette: profile.texture.vignette, deharsh: profile.texture.deharsh ?? 0 },
    passthrough: profile.passthrough === true,
  });
  let hash = 2166136261;
  for (let i = 0; i < payload.length; i++) hash = Math.imul(hash ^ payload.charCodeAt(i), 16777619);
  return (hash >>> 0).toString(16).padStart(8, '0');
}

export function describeRecipe(profile: CameraProfile, factory?: CameraProfile): string {
  const recipe = profile.recipe;
  const fingerprint = renderedFingerprint(profile);
  const factoryMatch = factory ? fingerprint === renderedFingerprint(factory) : null;
  return `${profile.ui.shortName}: ${recipe?.version ?? 'legacy/unversioned'} · ${recipe?.status ?? 'unverified'} · ${fingerprint}`
    + (factoryMatch === null ? '' : factoryMatch ? ' · matches bundled parameters' : ' · differs from bundled parameters')
    + ` · grain=${profile.texture.grain.amount}`;
}
