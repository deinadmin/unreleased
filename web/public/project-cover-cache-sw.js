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
