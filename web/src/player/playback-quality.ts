export type PlaybackQuality = "original" | "standard" | "high"

export const PLAYBACK_QUALITY_KEY = "audio.playback.quality"
export const DEFAULT_PLAYBACK_QUALITY: PlaybackQuality = "standard"

export const PLAYBACK_QUALITIES: ReadonlyArray<{
  id: PlaybackQuality
  title: string
  detail: string
}> = [
  {
    id: "standard",
    title: "Standard",
    detail: "AAC 160 kbps · Recommended",
  },
  {
    id: "high",
    title: "High",
    detail: "AAC 256 kbps · Uses more data",
  },
  {
    id: "original",
    title: "Lossless / Original",
    detail: "Uploaded source · Highest data usage",
  },
]

export function loadPlaybackQuality(): PlaybackQuality {
  try {
    const stored = localStorage.getItem(PLAYBACK_QUALITY_KEY)
    if (stored === "original" || stored === "standard" || stored === "high") return stored
  } catch {
    // Private browsing can make localStorage unavailable.
  }
  return DEFAULT_PLAYBACK_QUALITY
}

export function persistPlaybackQuality(quality: PlaybackQuality): void {
  try {
    localStorage.setItem(PLAYBACK_QUALITY_KEY, quality)
  } catch {
    // Playback still uses the in-memory selection for this session.
  }
}

export function renditionStoragePath(
  originalStoragePath: string,
  quality: Exclude<PlaybackQuality, "original">,
): string | undefined {
  const version = /^users\/([^/]+)\/audio\/versions\/([^/]+)\/[^/]+$/.exec(originalStoragePath)
  if (version) {
    return `users/${version[1]}/audio-renditions/versions/${version[2]}/${quality}.m4a`
  }

  const track = /^users\/([^/]+)\/audio\/([^/]+)$/.exec(originalStoragePath)
  if (!track) return undefined
  const trackID = track[2].replace(/\.[^.]+$/, "")
  return `users/${track[1]}/audio-renditions/tracks/${trackID}/${quality}.m4a`
}
