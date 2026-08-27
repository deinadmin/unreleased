import { getDownloadURL, ref } from "firebase/storage"
import { storage } from "./firebase"
import {
  renditionStoragePath,
  type PlaybackQuality,
} from "@/player/playback-quality"

const STORAGE_KEY_PREFIX = "downloadURL:"

const cache = new Map<string, Promise<string>>()
// In-memory mirror of resolved values so they can be read synchronously (e.g. on first render).
const resolvedCache = new Map<string, string>()

function readPersisted(storagePath: string): string | undefined {
  try {
    return localStorage.getItem(STORAGE_KEY_PREFIX + storagePath) ?? undefined
  } catch {
    return undefined
  }
}

function persist(storagePath: string, url: string) {
  try {
    localStorage.setItem(STORAGE_KEY_PREFIX + storagePath, url)
  } catch {
    // Ignore storage errors (e.g. quota exceeded, private browsing).
  }
}

function removePersisted(storagePath: string) {
  try {
    localStorage.removeItem(STORAGE_KEY_PREFIX + storagePath)
  } catch {
    // Ignore storage errors (e.g. private browsing).
  }
}

/** Synchronously returns a previously resolved download URL, if any (memory or persisted). */
export function cachedDownloadURL(storagePath: string): string | undefined {
  const inMemory = resolvedCache.get(storagePath)
  if (inMemory) return inMemory
  const persisted = readPersisted(storagePath)
  if (persisted) resolvedCache.set(storagePath, persisted)
  return persisted
}

/** Resolves (and caches, in memory and across reloads) a download URL for a Cloud Storage object path. */
export function downloadURL(storagePath: string): Promise<string> {
  if (/^https?:\/\//.test(storagePath)) return Promise.resolve(storagePath)

  const cached = cachedDownloadURL(storagePath)
  if (cached) return Promise.resolve(cached)

  let promise = cache.get(storagePath)
  if (!promise) {
    promise = getDownloadURL(ref(storage, storagePath)).then((url) => {
      resolvedCache.set(storagePath, url)
      persist(storagePath, url)
      return url
    })
    promise.catch(() => cache.delete(storagePath))
    cache.set(storagePath, promise)
  }
  return promise
}

export interface PlaybackSource {
  url: string
  storagePath: string
  isOriginal: boolean
}

/** Resolves the preferred AAC rendition and safely falls back to the original. */
export async function playbackSource(
  originalStoragePath: string,
  quality: PlaybackQuality,
): Promise<PlaybackSource> {
  if (quality === "original") {
    return {
      url: await downloadURL(originalStoragePath),
      storagePath: originalStoragePath,
      isOriginal: true,
    }
  }

  // Public share URLs are resolved by the authorized streaming function, which
  // always serves Standard quality (with original fallback) server-side. A
  // listener must sign in and accept the project before personal High/Original
  // settings apply.
  if (/^https?:\/\//.test(originalStoragePath)) {
    const url = new URL(originalStoragePath)
    url.searchParams.set("quality", "standard")
    return { url: url.toString(), storagePath: originalStoragePath, isOriginal: false }
  }

  const renditionPath = renditionStoragePath(originalStoragePath, quality)
  if (renditionPath) {
    try {
      return {
        // Do a fresh metadata lookup for renditions. Unlike originals, these
        // are created asynchronously and can be replaced by a retry/backfill;
        // a persisted download token could therefore be stale.
        url: await getDownloadURL(ref(storage, renditionPath)),
        storagePath: renditionPath,
        isOriginal: false,
      }
    } catch {
      // A new upload may still be transcoding, or a legacy format may not have
      // renditions. The original remains the always-playable source of truth.
    }
  }

  return {
    url: await downloadURL(originalStoragePath),
    storagePath: originalStoragePath,
    isOriginal: true,
  }
}

/** Clears a URL that is stale because its object was replaced or its token was revoked. */
export function invalidateDownloadURL(storagePath: string): void {
  cache.delete(storagePath)
  resolvedCache.delete(storagePath)
  removePersisted(storagePath)
}

/** Removes every bearer URL retained for the previous signed-in account. */
export function clearDownloadURLCache(): void {
  cache.clear()
  resolvedCache.clear()
  try {
    for (let index = localStorage.length - 1; index >= 0; index--) {
      const key = localStorage.key(index)
      if (key?.startsWith(STORAGE_KEY_PREFIX)) localStorage.removeItem(key)
    }
  } catch {
    // Storage can be unavailable in private browsing.
  }
}

/**
 * Re-resolves a playback source after a load failure.
 *
 * A Firebase download URL embeds the object's download token, and the server
 * rotates that token whenever access is revoked (a version turned private, a
 * listener removed, a share link switched off). Every URL cached here — in
 * memory and in localStorage — dies with it. Losing access should fail, but a
 * listener who still has access should not have to reload the page, so one
 * retry against a freshly minted URL tells the two cases apart.
 */
export async function refreshedPlaybackSource(
  originalStoragePath: string,
  quality: PlaybackQuality,
): Promise<PlaybackSource> {
  invalidateDownloadURL(originalStoragePath)
  if (quality !== "original") {
    const renditionPath = renditionStoragePath(originalStoragePath, quality)
    if (renditionPath) invalidateDownloadURL(renditionPath)
  }
  return playbackSource(originalStoragePath, quality)
}
