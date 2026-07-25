import { useEffect, useState } from "react"
import { cachedProjectCoverURL, projectCoverURL } from "@/lib/project-cover-cache"
import { cachedDownloadURL } from "@/lib/storage-urls"

/**
 * Resolves a project cover to an object URL backed by Cache Storage. Route
 * changes are synchronous from memory; reloads read the image bytes from the
 * browser's persistent cache instead of Firebase Storage.
 */
export function useStorageUrl(storagePath: string | undefined): string | undefined {
  const synchronousURL = storagePath
    ? cachedProjectCoverURL(storagePath) ?? cachedDownloadURL(storagePath)
    : undefined
  const [resolved, setResolved] = useState<{ path: string | undefined; url: string | undefined }>(
    () => ({ path: storagePath, url: synchronousURL }),
  )

  useEffect(() => {
    if (!storagePath) {
      setResolved({ path: undefined, url: undefined })
      return
    }
    const cached = cachedProjectCoverURL(storagePath)
    if (cached) {
      setResolved({ path: storagePath, url: cached })
      return
    }
    const directURL = cachedDownloadURL(storagePath)
    if (directURL) {
      setResolved({ path: storagePath, url: directURL })
      return
    }
    setResolved({ path: storagePath, url: undefined })
    let cancelled = false
    projectCoverURL(storagePath)
      .then((resolved) => {
        if (!cancelled) setResolved({ path: storagePath, url: resolved })
      })
      .catch(() => {
        if (!cancelled) setResolved({ path: storagePath, url: undefined })
      })
    return () => {
      cancelled = true
    }
  }, [storagePath])

  return resolved.path === storagePath ? resolved.url : synchronousURL
}
