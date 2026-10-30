/** Keep viewer failures separate from capture/save failures and from one another. */
export function photoPreviewFailureKey(code: string) {
  switch (code) {
    case 'ERR_PHOTO_PREVIEW_MISSING': return 'photoPreviewMissing';
    case 'ERR_PHOTO_PREVIEW_DECODE': return 'photoPreviewDecode';
    case 'ERR_PHOTO_PREVIEW_COPY': return 'photoPreviewCopy';
    case 'ERR_PHOTO_PREVIEW_READ': return 'photoPreviewRead';
    case 'ERR_PHOTO_READ_DENIED': return 'photoPreviewPermission';
    case 'ERR_NO_ACTIVE_VIEW': return 'photoPreviewWindow';
    case 'ERR_CAPTURE_BUSY': return 'errCaptureBusy';
    default: return 'photoUnavailable';
  }
}
