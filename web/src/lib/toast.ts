/**
 * Toast store. Kept free of React so it can be imported from anywhere,
 * including modules the toast viewport itself depends on.
 *
 * Toasts stack upward from the bottom-left corner, above the pinned upload
 * progress card. Five live at once; a sixth pushes the oldest out. The upload
 * card is not part of this store, so progress is never evicted.
 */

export type ToastVariant = "default" | "success" | "error"

export interface ToastOptions {
  description?: string
  /** Milliseconds before the toast dismisses itself. Pass 0 to keep it up. */
  duration?: number
}

export interface ToastItem {
  id: string
  variant: ToastVariant
  title: string
  description?: string
  /** True while the exit animation plays, just before removal. */
  exiting: boolean
}

const MAX_VISIBLE = 5
const DEFAULT_DURATION = 5000
/** Must match the exit animation in the viewport. */
const EXIT_DURATION = 200

interface Timer {
  handle: number
  endsAt: number
  remaining: number
}

let items: ToastItem[] = []
const listeners = new Set<() => void>()
const timers = new Map<string, Timer>()

function notify() {
  listeners.forEach((listener) => listener())
}

function clearTimer(id: string) {
  const timer = timers.get(id)
  if (!timer) return
  window.clearTimeout(timer.handle)
  timers.delete(id)
}

function startTimer(id: string, remaining: number) {
  clearTimer(id)
  timers.set(id, {
    handle: window.setTimeout(() => dismissToast(id), remaining),
    endsAt: Date.now() + remaining,
    remaining,
  })
}

export function dismissToast(id: string): void {
  clearTimer(id)
  const item = items.find((candidate) => candidate.id === id)
  if (!item || item.exiting) return
  items = items.map((candidate) =>
    candidate.id === id ? { ...candidate, exiting: true } : candidate,
  )
  notify()
  window.setTimeout(() => {
    items = items.filter((candidate) => candidate.id !== id)
    notify()
  }, EXIT_DURATION)
}

/** Holds every countdown while the pointer rests on the stack. */
export function pauseToasts(): void {
  for (const [id, timer] of timers) {
    window.clearTimeout(timer.handle)
    timers.set(id, { ...timer, remaining: Math.max(0, timer.endsAt - Date.now()) })
  }
}

export function resumeToasts(): void {
  for (const [id, timer] of [...timers]) startTimer(id, timer.remaining)
}

function push(variant: ToastVariant, title: string, options?: ToastOptions): string {
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
  const live = items.filter((item) => !item.exiting)
  if (live.length >= MAX_VISIBLE) dismissToast(live[0].id)

  items = [...items, { id, variant, title, description: options?.description, exiting: false }]
  notify()

  const duration = options?.duration ?? DEFAULT_DURATION
  if (duration > 0) startTimer(id, duration)
  return id
}

export const toast = Object.assign(
  (title: string, options?: ToastOptions) => push("default", title, options),
  {
    success: (title: string, options?: ToastOptions) => push("success", title, options),
    error: (title: string, options?: ToastOptions) => push("error", title, options),
    dismiss: dismissToast,
  },
)

export function subscribeToasts(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function getToasts(): ToastItem[] {
  return items
}
