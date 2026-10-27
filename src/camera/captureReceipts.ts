/** Consume only the reservation owned by this exposure; PhotoKit can finish out of order. */
export function takeCaptureReservation<T extends { captureID: string }>(pending: T[], captureID?: string): T | undefined {
  if (!captureID) return undefined;
  const index = pending.findIndex((reservation) => reservation.captureID === captureID);
  return index < 0 ? undefined : pending.splice(index, 1)[0];
}
