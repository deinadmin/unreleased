const CACHE_NAME = "unreleased-project-covers-v1"
const MAX_CACHED_COVERS = 128
const inFlight = new Map()

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()))

function isProjectCoverRequest(request) {
  if (request.method !== "GET" || request.destination !== "image") return false
  const url = new URL(request.url)
  if (
    url.hostname !== "firebasestorage.googleapis.com" &&
    !url.hostname.endsWith(".firebasestorage.app") &&
    url.hostname !== "storage.googleapis.com"
  ) {
    return false
  }
  try {
    return decodeURIComponent(url.pathname).includes("/covers/")
  } catch {
    return url.pathname.includes("%2Fcovers%2F")
  }
}

async function prune(cache) {
  const keys = await cache.keys()
  if (keys.length <= MAX_CACHED_COVERS) return
  await Promise.all(keys.slice(0, keys.length - MAX_CACHED_COVERS).map((key) => cache.delete(key)))
}

async function cacheFirst(request) {
  const cache = await caches.open(CACHE_NAME)
  const cached = await cache.match(request, { ignoreVary: true })
  if (cached) return cached

  let requestPromise = inFlight.get(request.url)
  if (!requestPromise) {
    requestPromise = fetch(request)
      .then(async (response) => {
        // Cross-origin <img> responses are usually opaque (status 0), but they
        // are valid Cache Storage entries and can be replayed by a service worker.
        if (response.ok || response.type === "opaque") {
          await cache.put(request, response.clone())
          await prune(cache)
        }
        return response
      })
      .finally(() => inFlight.delete(request.url))
    inFlight.set(request.url, requestPromise)
  }
  const response = await requestPromise
  return response.clone()
}

self.addEventListener("fetch", (event) => {
  if (isProjectCoverRequest(event.request)) {
    event.respondWith(cacheFirst(event.request))
  }
})

// MARK: - Played-track cache

const TRACK_CACHE_NAME = "unreleased-played-tracks-v1"
const TRACK_METADATA_CACHE_NAME = "unreleased-played-track-metadata-v1"
const TRACK_CACHE_PATH = "/__unreleased_cache__/played-track"
const MAX_CACHED_TRACKS = 32
const MAX_TRACK_CACHE_BYTES = 1024 * 1024 * 1024
const DEFAULT_TRACK_CACHE_BYTES = 512 * 1024 * 1024
const TRACK_QUOTA_FRACTION = 0.25
const TRACK_STORAGE_HIGH_WATER_MARK = 0.85
const trackDownloads = new Map()
const announcedTrackSizes = new Map()
const trackGenerations = new Map()

function storagePathForURL(url) {
  try {
    const parsed = new URL(url)
    if (
      parsed.hostname !== "firebasestorage.googleapis.com" &&
      !parsed.hostname.endsWith(".firebasestorage.app") &&
      parsed.hostname !== "storage.googleapis.com"
    ) {
      return undefined
    }

    // Firebase download URLs use `/v0/b/{bucket}/o/{encoded object path}`.
    const firebaseObjectMarker = "/o/"
    const objectIndex = parsed.pathname.indexOf(firebaseObjectMarker)
    if (objectIndex >= 0) {
      return decodeURIComponent(parsed.pathname.slice(objectIndex + firebaseObjectMarker.length))
    }

    // Direct Google Storage URLs use `/{bucket}/{object path}`.
    if (parsed.hostname === "storage.googleapis.com") {
      const parts = parsed.pathname.split("/").filter(Boolean)
      if (parts.length >= 2) return decodeURIComponent(parts.slice(1).join("/"))
    }

    if (parsed.hostname.endsWith(".firebasestorage.app")) {
      const directObjectPath = parsed.pathname.replace(/^\/+/, "")
      if (directObjectPath) return decodeURIComponent(directObjectPath)
    }
  } catch {
    // A malformed or non-storage URL is not a track request.
  }
  return undefined
}

function isTrackRequest(request) {
  if (request.method !== "GET") return false
  const storagePath = storagePathForURL(request.url)
  if (
    !storagePath ||
    (!storagePath.includes("/audio/") && !storagePath.includes("/audio-renditions/"))
  ) return false
  // Media-element requests use `audio`; Safari can expose an empty destination
  // for a byte-range request, so the Range header is the conservative fallback.
  return request.destination === "audio" || (request.destination === "" && request.headers.has("range"))
}

function responseModeFor(request) {
  return request.mode === "cors" ? "cors" : "opaque"
}

function trackCacheRequest(storagePath, mode) {
  const url = new URL(TRACK_CACHE_PATH, self.location.origin)
  url.searchParams.set("path", storagePath)
  url.searchParams.set("mode", mode)
  return new Request(url)
}

function fullTrackRequest(request) {
  const headers = new Headers(request.headers)
  headers.delete("range")
  headers.delete("if-range")
  headers.delete("if-none-match")
  headers.delete("if-modified-since")
  return new Request(request.url, {
    method: "GET",
    headers,
    mode: request.mode,
    credentials: request.credentials,
    cache: "no-store",
    redirect: request.redirect,
    referrer: request.referrer,
    referrerPolicy: request.referrerPolicy,
    integrity: request.integrity,
  })
}

function validTrackSize(value) {
  return Number.isFinite(value) && value > 0 ? Math.round(value) : 0
}

function trackGeneration(storagePath) {
  return trackGenerations.get(storagePath) ?? 0
}

async function readTrackMetadata(metadataCache, request) {
  const response = await metadataCache.match(request)
  if (!response) return { size: 0, accessedAt: 0 }
  return {
    size: validTrackSize(Number(response.headers.get("x-unreleased-size"))),
    accessedAt: Number(response.headers.get("x-unreleased-accessed-at")) || 0,
  }
}

async function writeTrackMetadata(metadataCache, request, size) {
  await metadataCache.put(
    request,
    new Response(null, {
      headers: {
        "x-unreleased-size": String(validTrackSize(size)),
        "x-unreleased-accessed-at": String(Date.now()),
      },
    }),
  )
}

async function trackCacheBudget(currentTrackBytes) {
  try {
    const estimate = await self.navigator.storage?.estimate()
    if (!estimate?.quota) return DEFAULT_TRACK_CACHE_BYTES
    const quotaBudget = Math.min(
      MAX_TRACK_CACHE_BYTES,
      Math.floor(estimate.quota * TRACK_QUOTA_FRACTION),
    )
    const usage = estimate.usage ?? 0
    const nonTrackUsage = Math.max(0, usage - currentTrackBytes)
    const availableBeforeHighWater = Math.max(
      0,
      Math.floor(estimate.quota * TRACK_STORAGE_HIGH_WATER_MARK - nonTrackUsage),
    )
    return Math.min(quotaBudget, availableBeforeHighWater)
  } catch {
    return DEFAULT_TRACK_CACHE_BYTES
  }
}

async function makeRoomForTrack(trackCache, metadataCache, incomingSize, protectedURL) {
  const keys = await trackCache.keys()
  const entries = await Promise.all(
    keys.map(async (request) => ({
      request,
      ...(await readTrackMetadata(metadataCache, request)),
    })),
  )
  const currentBytes = entries.reduce((total, entry) => total + entry.size, 0)
  const budget = await trackCacheBudget(currentBytes)
  const existing = entries.find((entry) => entry.request.url === protectedURL)
  let projectedBytes = currentBytes - (existing?.size ?? 0) + incomingSize
  let projectedCount = entries.length + (existing ? 0 : 1)

  entries.sort((a, b) => a.accessedAt - b.accessedAt)
  for (const entry of entries) {
    if (
      projectedCount <= MAX_CACHED_TRACKS &&
      (incomingSize === 0 || projectedBytes <= budget)
    ) {
      break
    }
    if (entry.request.url === protectedURL) continue
    await Promise.all([
      trackCache.delete(entry.request),
      metadataCache.delete(entry.request),
    ])
    projectedBytes -= entry.size
    projectedCount--
  }

  // Files larger than the whole safe budget should stream normally instead of
  // pushing every other cached track out and then failing with quota pressure.
  return incomingSize === 0 || incomingSize <= budget
}

async function persistTrackResponse(cacheRequest, response, storagePath, expectedGeneration) {
  const [trackCache, metadataCache] = await Promise.all([
    caches.open(TRACK_CACHE_NAME),
    caches.open(TRACK_METADATA_CACHE_NAME),
  ])
  if (trackGeneration(storagePath) !== expectedGeneration) return
  const announcedSize = validTrackSize(announcedTrackSizes.get(storagePath))
  const responseSize = validTrackSize(Number(response.headers.get("content-length")))
  const size = announcedSize || responseSize
  const hasRoom = await makeRoomForTrack(trackCache, metadataCache, size, cacheRequest.url)
  if (!hasRoom || trackGeneration(storagePath) !== expectedGeneration) return

  try {
    await trackCache.put(cacheRequest, response)
    if (trackGeneration(storagePath) !== expectedGeneration) {
      await trackCache.delete(cacheRequest)
      return
    }
    await writeTrackMetadata(metadataCache, cacheRequest, size)
    if (trackGeneration(storagePath) !== expectedGeneration) {
      await Promise.all([
        trackCache.delete(cacheRequest),
        metadataCache.delete(cacheRequest),
      ])
    }
  } catch (error) {
    // Cache Storage is best-effort (private browsing and quota policies vary).
    // Remove a partial entry, but never interfere with the network playback.
    await Promise.all([
      trackCache.delete(cacheRequest).catch(() => false),
      metadataCache.delete(cacheRequest).catch(() => false),
    ])
    if (error?.name !== "QuotaExceededError") {
      console.warn("Played-track cache write failed", error)
    }
  }
}

async function serveTrack(request) {
  const storagePath = storagePathForURL(request.url)
  if (!storagePath) {
    return { response: await fetch(request), background: Promise.resolve() }
  }
  const mode = responseModeFor(request)
  const cacheRequest = trackCacheRequest(storagePath, mode)
  const trackCache = await caches.open(TRACK_CACHE_NAME)
  const cached = await trackCache.match(cacheRequest)
  if (cached) {
    const background = caches
      .open(TRACK_METADATA_CACHE_NAME)
      .then(async (metadataCache) => {
        const previous = await readTrackMetadata(metadataCache, cacheRequest)
        const announced = validTrackSize(announcedTrackSizes.get(storagePath))
        await writeTrackMetadata(metadataCache, cacheRequest, announced || previous.size)
      })
      .catch(() => {})
    return { response: cached, background }
  }

  const existing = trackDownloads.get(cacheRequest.url)
  if (existing) {
    await existing
    const completed = await trackCache.match(cacheRequest)
    if (completed) {
      const background = caches
        .open(TRACK_METADATA_CACHE_NAME)
        .then(async (metadataCache) => {
          const previous = await readTrackMetadata(metadataCache, cacheRequest)
          const announced = validTrackSize(announcedTrackSizes.get(storagePath))
          await writeTrackMetadata(metadataCache, cacheRequest, announced || previous.size)
        })
        .catch(() => {})
      return { response: completed, background }
    }
    return {
      response: await fetch(request),
      background: Promise.resolve(),
    }
  }

  const response = await fetch(fullTrackRequest(request))
  if (!(response.ok || response.type === "opaque")) {
    return { response, background: Promise.resolve() }
  }

  const expectedGeneration = trackGeneration(storagePath)
  const persistence = persistTrackResponse(
    cacheRequest,
    response.clone(),
    storagePath,
    expectedGeneration,
  )
    .catch((error) => {
      console.warn("Played-track cache persistence failed", error)
    })
    .finally(() => {
      if (trackDownloads.get(cacheRequest.url) === persistence) {
        trackDownloads.delete(cacheRequest.url)
      }
    })
  trackDownloads.set(cacheRequest.url, persistence)
  return { response, background: persistence }
}

async function deleteCachedTrack(storagePath) {
  trackGenerations.set(storagePath, trackGeneration(storagePath) + 1)
  const [trackCache, metadataCache] = await Promise.all([
    caches.open(TRACK_CACHE_NAME),
    caches.open(TRACK_METADATA_CACHE_NAME),
  ])
  await Promise.all(
    ["cors", "opaque"].flatMap((mode) => {
      const request = trackCacheRequest(storagePath, mode)
      trackDownloads.delete(request.url)
      return [trackCache.delete(request), metadataCache.delete(request)]
    }),
  )
  announcedTrackSizes.delete(storagePath)
}

self.addEventListener("message", (event) => {
  const message = event.data
  if (!message || typeof message !== "object") return
  if (message.type === "UNRELEASED_TRACK_CACHE_METADATA" && typeof message.storagePath === "string") {
    announcedTrackSizes.set(message.storagePath, validTrackSize(message.size))
  }
  if (message.type === "UNRELEASED_TRACK_CACHE_DELETE" && typeof message.storagePath === "string") {
    event.waitUntil(deleteCachedTrack(message.storagePath))
  }
})

self.addEventListener("fetch", (event) => {
  if (!isTrackRequest(event.request)) return
  const operation = serveTrack(event.request)
  event.respondWith(operation.then(({ response }) => response))
  event.waitUntil(
    operation
      .then(({ background }) => background)
      .catch(() => {}),
  )
})
