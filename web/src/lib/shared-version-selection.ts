/**
 * Active version choices for shared projects. The owner's project document is
 * read-only for listeners, so the pick is kept on this device only — mirroring
 * the iOS `ProjectStore.selectVersion` branch that calls `persistLocalOnly()`.
 */

const STORAGE_KEY = "sharedVersionSelection"

type Selection = Record<string, string>

function read(): Selection {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    const parsed = raw ? (JSON.parse(raw) as unknown) : null
    return parsed && typeof parsed === "object" ? (parsed as Selection) : {}
  } catch {
    return {}
  }
}

let selection = read()
let revision = 0
const listeners = new Set<() => void>()

const key = (projectID: string, trackID: string) => `${projectID}/${trackID}`

export function sharedVersionSelection(projectID: string, trackID: string): string | undefined {
  return selection[key(projectID, trackID)]
}

export function setSharedVersionSelection(
  projectID: string,
  trackID: string,
  versionID: string,
): void {
  if (selection[key(projectID, trackID)] === versionID) return
  selection = { ...selection, [key(projectID, trackID)]: versionID }
  revision++
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(selection))
  } catch {
    // Ignore storage errors (e.g. quota exceeded, private browsing).
  }
  listeners.forEach((listener) => listener())
}

export function subscribeSharedVersionSelection(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function sharedVersionSelectionRevision(): number {
  return revision
}
