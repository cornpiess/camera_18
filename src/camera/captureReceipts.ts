/** Consume only the reservation owned by this exposure; PhotoKit can finish out of order. */
export function takeCaptureReservation<T extends { captureID: string }>(pending: T[], captureID?: string): T | undefined {
  if (!captureID) return undefined;
  const index = pending.findIndex((reservation) => reservation.captureID === captureID);
  return index < 0 ? undefined : pending.splice(index, 1)[0];
}

/** Recoverable delivery preserves the reservation until a final result arrives. */
export function settleCaptureReservation<T extends { captureID: string }>(pending: T[], result: { captureID?: string; terminal?: boolean }): T | undefined {
  return result.terminal === false ? undefined : takeCaptureReservation(pending, result.captureID);
}

export function canRequestCapture(state: { ready: boolean }, opticsPending: boolean, exposing: boolean): boolean {
  return state.ready && !opticsPending && !exposing;
}

/** The viewfinder is quiet during ordinary work. Only actual failures need an action. */
export function captureRecoveryAction(
  state: { reason: string }, delivery: { waiting: number },
): 'camera' | 'aperture' | 'photos' | null {
  if (state.reason === 'unavailable') return 'camera';
  if (state.reason === 'aperture') return 'aperture';
  return delivery.waiting > 0 ? 'photos' : null;
}
