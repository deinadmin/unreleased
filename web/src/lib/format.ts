export function formatDuration(seconds: number): string {
  if (!seconds || seconds <= 0) return "--:--"
  return formatPlaybackTime(seconds)
}

/** Like `formatDuration` but renders zero as `0:00` (for elapsed time). */
export function formatPlaybackTime(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds || 0))
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`
}

export function formatFileSize(bytes: number): string {
  if (bytes < 1_000) return `${Math.round(bytes)} B`
  if (bytes < 1_000_000) return `${Math.round(bytes / 1_000)} KB`
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`
  return `${(bytes / 1_000_000_000).toFixed(2)} GB`
}

/** Abbreviated calendar date, matching the iOS `.abbreviated` date style. */
export function formatShortDate(date: Date): string {
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })
}

const rtf = new Intl.RelativeTimeFormat("en", { numeric: "auto" })

export function formatRelativeDate(date: Date): string {
  const seconds = (date.getTime() - Date.now()) / 1000
  const table: [Intl.RelativeTimeFormatUnit, number][] = [
    ["year", 31_536_000],
    ["month", 2_592_000],
    ["week", 604_800],
    ["day", 86_400],
    ["hour", 3_600],
    ["minute", 60],
  ]
  for (const [unit, secondsPerUnit] of table) {
    if (Math.abs(seconds) >= secondsPerUnit) {
      return rtf.format(Math.round(seconds / secondsPerUnit), unit)
    }
  }
  return "just now"
}

export function formatProjectDuration(totalSeconds: number, trackCount: number): string {
  if (trackCount === 0) return "0 min"
  const minutes = Math.floor(totalSeconds / 60)
  if (minutes === 0) return "< 1 min"
  return `${minutes} min`
}
