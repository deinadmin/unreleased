/**
 * Claimed by any surface that handles its own audio drops (the versions
 * dialog), so the page-wide `AudioDropzone` behind it stops reacting. A modal
 * overlay does not block drag events on its own — Radix leaves it
 * pointer-transparent — so the page dropzone has to opt out explicitly.
 */

let locks = 0
const listeners = new Set<() => void>()

/** Takes the lock and returns the release function. */
export function lockAudioDrop(): () => void {
  locks++
  listeners.forEach((listener) => listener())
  return () => {
    locks = Math.max(0, locks - 1)
    listeners.forEach((listener) => listener())
  }
}

export function subscribeAudioDropLock(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function isAudioDropLocked(): boolean {
  return locks > 0
}
