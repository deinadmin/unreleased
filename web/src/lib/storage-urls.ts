import { getDownloadURL, ref } from "firebase/storage"
import { storage } from "./firebase"

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

/** Clears a URL that is stale because its object was replaced or its token was revoked. */
export function invalidateDownloadURL(storagePath: string): void {
  cache.delete(storagePath)
  resolvedCache.delete(storagePath)
  removePersisted(storagePath)
}
