import { useCallback } from "react"
import { toast } from "@/lib/toast"
import { useAuth } from "@/hooks/use-auth"
import { setSharedVersionSelection } from "@/lib/shared-version-selection"
import type { Project } from "@/lib/types"
import { selectVersion } from "@/lib/version-edits"

/**
 * Persists the active version of a track. Owned projects write to Firestore;
 * shared ones can only be read, so the pick stays on this device — the same
 * split the iOS `ProjectStore.selectVersion` makes with `persistLocalOnly()`.
 */
export function useSetActiveVersion() {
  const { user } = useAuth()

  return useCallback(
    (project: Project, trackID: string, versionID: string) => {
      if (project.ownerID) {
        setSharedVersionSelection(project.id, trackID, versionID)
        return
      }
      if (!user) return
      selectVersion(user.uid, project, trackID, versionID).catch((error) => {
        console.error("selecting version failed", error)
        toast("Couldn't switch version. Please try again.")
      })
    },
    [user],
  )
}
