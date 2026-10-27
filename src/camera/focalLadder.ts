/** Focal stops express framing intent. Native capture normally uses Apple's virtual
 * multi-camera device; these lens/zoom fields also support physical fallback and
 * explicit main-lens iris control without adding a second UI mode. */

export type PhysicalLens = 'ultrawide' | 'wide' | 'tele';

export interface FocalStop {
  /** Stable stop id (dial keys, EXIF provenance): "uw-13" / "wide-26" / "tele-77" … */
  readonly id: string;
  /** 35mm-equivalent focal length in millimeters (displayed on the dial; EXIF stamped). */
  readonly mm: number;
  /** Preferred lens for physical fallback / explicit iris control. */
  readonly lens: PhysicalLens;
  /** Crop factor in physical-lens coordinates (native maps virtual devices) (1.0 for ultrawide/tele stops). */
  readonly zoom: number;
}

const WIDE_BASE_MM = 26;
/** Ultra-wide base; the tele stop's mm = UW_BASE_MM × inventory.teleZoom. */
const UW_BASE_MM = 13;

export interface LensInventory {
  /** A physical builtInUltraWideCamera exists. */
  readonly ultraWide: boolean;
  /** A physical builtInTelephotoCamera exists. */
  readonly tele: boolean;
  /** Tele's native multiplier over the 13mm base (nil = unknown / no tele). */
  readonly teleZoom?: number | null;
}

/**
 * Ladder (capability-driven — a stop without its physical lens is HIDDEN):
 *   [13 (real UW)] 26 -> 35 -> 52 (physical main crops) [tele at its own mm].
 */
export function buildFocalStops(inventory: LensInventory): FocalStop[] {
  const stops: FocalStop[] = [];
  if (inventory.ultraWide) {
    stops.push({ id: 'uw-13', mm: 13, lens: 'ultrawide', zoom: 1.0 });
  }
  stops.push({ id: 'wide-26', mm: 26, lens: 'wide', zoom: 1.0 });
  stops.push({ id: 'wide-35', mm: 35, lens: 'wide', zoom: 35 / WIDE_BASE_MM });
  stops.push({ id: 'wide-52', mm: 52, lens: 'wide', zoom: 52 / WIDE_BASE_MM });
  const teleZoom = inventory.teleZoom;
  if (
    inventory.tele &&
    typeof teleZoom === 'number' &&
    Number.isFinite(teleZoom) &&
    teleZoom > 0
  ) {
    const teleMm = Math.round(UW_BASE_MM * teleZoom);
    if (teleMm > 52 && !stops.some((stop) => stop.mm === teleMm)) {
      stops.push({ id: `tele-${teleMm}`, mm: teleMm, lens: 'tele', zoom: 1.0 });
    }
  }
  return stops;
}

/** Default stop: the physical main camera at 26mm (zoom 1.0). */
export function defaultFocalStop(): FocalStop {
  return { id: 'wide-26', mm: 26, lens: 'wide', zoom: 1.0 };
}
