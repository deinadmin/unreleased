import { useEffect, useState } from "react"
import { cachedDownloadURL, downloadURL } from "@/lib/storage-urls"

/**
 * Resolves a Cloud Storage path to a download URL (cached in memory and across reloads
 * via localStorage, so already-seen artwork renders immediately instead of popping in).
 */
export function useStorageUrl(storagePath: string | undefined): string | undefined {
  const [url, setUrl] = useState<string | undefined>(() => storagePath && cachedDownloadURL(storagePath))

  useEffect(() => {
    if (!storagePath) {
      setUrl(undefined)
      return
    }
    const cached = cachedDownloadURL(storagePath)
    if (cached) {
      setUrl(cached)
      return
    }
    let cancelled = false
    downloadURL(storagePath)
      .then((resolved) => {
        if (!cancelled) setUrl(resolved)
      })
      .catch(() => {
        if (!cancelled) setUrl(undefined)
      })
    return () => {
      cancelled = true
    }
  }, [storagePath])

  return url
}
