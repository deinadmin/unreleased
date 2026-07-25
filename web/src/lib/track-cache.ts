const TRACK_CACHE_NAME = "unreleased-played-tracks-v1"
const TRACK_METADATA_CACHE_NAME = "unreleased-played-track-metadata-v1"
const TRACK_CACHE_PATH = "/__unreleased_cache__/played-track"

type CacheMode = "cors" | "opaque"

function cacheRequest(storagePath: string, mode: CacheMode): Request {
  const url = new URL(TRACK_CACHE_PATH, window.location.origin)
  url.searchParams.set("path", storagePath)
  url.searchParams.set("mode", mode)
  return new Request(url)
}

function serviceWorkerTarget(): Promise<ServiceWorker | undefined> {
  if (!("serviceWorker" in navigator)) return Promise.resolve(undefined)
  const current = navigator.serviceWorker.controller
  if (current) return Promise.resolve(current)
  return navigator.serviceWorker.ready
    .then((registration) => registration.active ?? undefined)
    .catch(() => undefined)
}

/**
 * Gives the service worker the authoritative file size before the media element
 * starts loading. The actual bytes are captured from that playback request, so
 * caching never adds a second download.
 */
export function preparePlayedTrackCache(storagePath: string, size: number): void {
  const current = navigator.serviceWorker?.controller
  if (current) {
    current.postMessage({
      type: "UNRELEASED_TRACK_CACHE_METADATA",
      storagePath,
      size,
    })
    return
  }
  void serviceWorkerTarget().then((worker) => {
    worker?.postMessage({
      type: "UNRELEASED_TRACK_CACHE_METADATA",
      storagePath,
      size,
    })
  })
}

/** Removes both CORS and plain-playback variants of a deleted audio object. */
export function invalidatePlayedTrackCache(storagePath: string): void {
  void serviceWorkerTarget().then((worker) => {
    worker?.postMessage({
      type: "UNRELEASED_TRACK_CACHE_DELETE",
      storagePath,
    })
  })

  // Direct Cache Storage cleanup covers pages that are not controlled by the
  // worker yet (notably the first visit after this feature is deployed).
  if (!("caches" in window)) return
  void Promise.all([caches.open(TRACK_CACHE_NAME), caches.open(TRACK_METADATA_CACHE_NAME)])
    .then(([trackCache, metadataCache]) =>
      Promise.all(
        (["cors", "opaque"] as const).flatMap((mode) => {
          const request = cacheRequest(storagePath, mode)
          return [trackCache.delete(request), metadataCache.delete(request)]
        }),
      ),
    )
    .catch(() => {})
}
