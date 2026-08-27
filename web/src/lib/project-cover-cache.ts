import { cachedDownloadURL, downloadURL, invalidateDownloadURL } from "./storage-urls"

const CACHE_NAME = "unreleased-project-covers-v1"
const CACHE_NAME_PREFIX = "unreleased-project-covers-"
const CACHE_KEY_PATH = "/__unreleased_cache__/project-cover"
const CACHED_AT_HEADER = "x-unreleased-cached-at"
const MAX_PERSISTED_COVERS = 128

// Object URLs make repeat renders and route changes entirely synchronous. They
// intentionally live for the page lifetime; revoking an in-use URL would make
// an already-rendered cover disappear.
const memoryCache = new Map<string, string>()
const pending = new Map<string, { promise: Promise<string>; controller: AbortController }>()
const generations = new Map<string, number>()
let cacheSetup: Promise<Cache | undefined> | undefined
let pruning: Promise<void> | undefined

function supportsPersistentCache(): boolean {
  return typeof window !== "undefined" && "caches" in window
}

function requestFor(storagePath: string): Request {
  const url = new URL(CACHE_KEY_PATH, window.location.origin)
  url.searchParams.set("path", storagePath)
  return new Request(url)
}

async function persistentCache(): Promise<Cache | undefined> {
  if (!supportsPersistentCache()) return undefined
  if (!cacheSetup) {
    cacheSetup = (async () => {
      // Drop superseded cache formats without touching unrelated app caches.
      const names = await window.caches.keys()
      await Promise.all(
        names
          .filter((name) => name.startsWith(CACHE_NAME_PREFIX) && name !== CACHE_NAME)
          .map((name) => window.caches.delete(name)),
      )
      return window.caches.open(CACHE_NAME)
    })().catch(() => undefined)
  }
  return cacheSetup
}

function remember(storagePath: string, blob: Blob): string {
  const existing = memoryCache.get(storagePath)
  if (existing) return existing
  const url = URL.createObjectURL(blob)
  memoryCache.set(storagePath, url)
  return url
}

function forgetFromMemory(storagePath: string): void {
  const url = memoryCache.get(storagePath)
  if (!url) return
  memoryCache.delete(storagePath)
  URL.revokeObjectURL(url)
}

function generation(storagePath: string): number {
  return generations.get(storagePath) ?? 0
}

function isCurrent(storagePath: string, expectedGeneration: number): boolean {
  return generation(storagePath) === expectedGeneration
}

function cancelledError(): Error {
  return new Error("Cover cache request was superseded")
}

async function readBlob(storagePath: string): Promise<Blob | undefined> {
  const cache = await persistentCache()
  if (!cache) return undefined
  const response = await cache.match(requestFor(storagePath))
  if (!response?.ok) return undefined
  const blob = await response.blob()
  if (blob.size === 0) {
    await cache.delete(requestFor(storagePath))
    return undefined
  }
  return blob
}

async function storeBlob(
  storagePath: string,
  blob: Blob,
  expectedGeneration: number,
): Promise<void> {
  const cache = await persistentCache()
  if (!cache || !isCurrent(storagePath, expectedGeneration)) return
  const headers = new Headers({
    "content-type": blob.type || "application/octet-stream",
    [CACHED_AT_HEADER]: String(Date.now()),
  })
  try {
    await cache.put(requestFor(storagePath), new Response(blob, { status: 200, headers }))
    // An upload/delete may have superseded this write while Cache Storage was
    // committing it. Never let that race resurrect an invalidated cover.
    if (!isCurrent(storagePath, expectedGeneration)) {
      await cache.delete(requestFor(storagePath))
      return
    }
    schedulePrune(cache)
  } catch {
    // Cache Storage may be unavailable or over quota. The in-memory cache and
    // direct Firebase URL remain valid fallbacks.
  }
}

function schedulePrune(cache: Cache): void {
  if (pruning) return
  pruning = prune(cache).finally(() => {
    pruning = undefined
  })
}

async function prune(cache: Cache): Promise<void> {
  try {
    const keys = await cache.keys()
    if (keys.length <= MAX_PERSISTED_COVERS) return
    const dated = await Promise.all(
      keys.map(async (request) => {
        const response = await cache.match(request)
        const cachedAt = Number(response?.headers.get(CACHED_AT_HEADER)) || 0
        return { request, cachedAt }
      }),
    )
    dated.sort((a, b) => a.cachedAt - b.cachedAt)
    await Promise.all(
      dated
        .slice(0, dated.length - MAX_PERSISTED_COVERS)
        .map(({ request }) => cache.delete(request)),
    )
  } catch {
    // Eviction is best-effort; browsers can also evict Cache Storage entries.
  }
}

async function fetchCover(
  storagePath: string,
  expectedGeneration: number,
  signal: AbortSignal,
): Promise<string> {
  const persisted = await readBlob(storagePath)
  if (!isCurrent(storagePath, expectedGeneration) || signal.aborted) throw cancelledError()
  if (persisted) return remember(storagePath, persisted)

  const remoteURL = await downloadURL(storagePath)
  if (!isCurrent(storagePath, expectedGeneration) || signal.aborted) throw cancelledError()
  // Give <img> the URL immediately. The service worker can cache opaque
  // cross-origin image bytes without delaying rendering for a CORS blob fetch.
  return remoteURL
}

/** Returns an already-decoded page-lifetime URL without any asynchronous work. */
export function cachedProjectCoverURL(storagePath: string): string | undefined {
  return memoryCache.get(storagePath)
}

/**
 * Returns a cover URL backed by a persistent binary cache. Concurrent callers
 * share one request, so a grid containing the same cover never downloads it
 * more than once.
 */
export function projectCoverURL(storagePath: string): Promise<string> {
  const cached = cachedProjectCoverURL(storagePath)
  if (cached) return Promise.resolve(cached)

  let request = pending.get(storagePath)
  if (!request) {
    const controller = new AbortController()
    const expectedGeneration = generation(storagePath)
    const promise = fetchCover(storagePath, expectedGeneration, controller.signal).finally(() => {
      if (pending.get(storagePath)?.promise === promise) pending.delete(storagePath)
    })
    request = { promise, controller }
    pending.set(storagePath, request)
  }
  return request.promise
}

/** Warms a cover opportunistically without surfacing failures to callers. */
export function preloadProjectCover(storagePath: string | undefined): void {
  if (!storagePath || typeof navigator === "undefined" || !navigator.serviceWorker?.controller) {
    return
  }
  void projectCoverURL(storagePath)
    .then((url) => {
      if (/^blob:/.test(url)) return
      // This request is intercepted and deduplicated by the cover service worker.
      return fetch(url, { mode: "no-cors", cache: "force-cache" }).then(() => undefined)
    })
    .catch(() => {})
}

/**
 * Seeds a newly uploaded cover directly from its local compressed blob, so the
 * Firestore snapshot can render it without downloading the upload back.
 */
export async function cacheUploadedProjectCover(storagePath: string, blob: Blob): Promise<void> {
  generations.set(storagePath, generation(storagePath) + 1)
  const expectedGeneration = generation(storagePath)
  pending.get(storagePath)?.controller.abort()
  pending.delete(storagePath)
  forgetFromMemory(storagePath)
  remember(storagePath, blob)
  await storeBlob(storagePath, blob, expectedGeneration)
}

/** Removes all local representations of a replaced or deleted cover. */
export async function invalidateProjectCover(storagePath: string | undefined): Promise<void> {
  if (!storagePath) return
  const remoteURL = cachedDownloadURL(storagePath)
  generations.set(storagePath, generation(storagePath) + 1)
  pending.get(storagePath)?.controller.abort()
  pending.delete(storagePath)
  forgetFromMemory(storagePath)
  invalidateDownloadURL(storagePath)
  const cache = await persistentCache()
  if (cache) {
    await Promise.all([
      cache.delete(requestFor(storagePath)).catch(() => false),
      remoteURL
        ? cache.delete(remoteURL, { ignoreVary: true }).catch(() => false)
        : Promise.resolve(false),
    ])
  }
}

/** Purges account-owned cover bytes and object URLs on sign-out. */
export async function clearProjectCoverCache(): Promise<void> {
  for (const request of pending.values()) request.controller.abort()
  pending.clear()
  for (const storagePath of [...memoryCache.keys()]) forgetFromMemory(storagePath)
  generations.clear()
  cacheSetup = undefined
  if (supportsPersistentCache()) {
    await window.caches.delete(CACHE_NAME).catch(() => false)
  }
}
