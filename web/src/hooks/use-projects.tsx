import {
  collection,
  doc,
  getDocFromServer,
  onSnapshot,
  orderBy,
  query,
} from "firebase/firestore"
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react"
import { useAuth } from "@/hooks/use-auth"
import { decodeProject } from "@/lib/codec"
import { db } from "@/lib/firebase"
import { normalizeProjectID, removeSharedRef, sharedRefsDoc } from "@/lib/invites"
import { preloadProjectCover } from "@/lib/project-cover-cache"
import {
  sharedVersionSelection,
  sharedVersionSelectionRevision,
  subscribeSharedVersionSelection,
} from "@/lib/shared-version-selection"
import { sharedPlayableProject, type Project } from "@/lib/types"

interface ProjectsContextValue {
  projects: Project[]
  loading: boolean
  materializeSharedProject: (ownerID: string, projectID: string) => Promise<Project | null>
}

/** Applies this device's local-only version picks to a shared project. */
function playableShared(project: Project): Project {
  return sharedPlayableProject(project, (trackID) =>
    sharedVersionSelection(project.id, trackID),
  )
}

const ProjectsContext = createContext<ProjectsContextValue>({
  projects: [],
  loading: true,
  materializeSharedProject: async () => null,
})

export function ProjectsProvider({ children }: { children: ReactNode }) {
  const { user, isSignedIn } = useAuth()
  const [ownProjects, setOwnProjects] = useState<Project[]>([])
  const [sharedProjects, setSharedProjects] = useState<Map<string, Project>>(new Map())
  const [loading, setLoading] = useState(true)

  /**
   * Loads an accepted shared project directly into the context. Acceptance uses
   * this before navigating so the destination route never observes a temporary
   * "missing" project while the shared-reference listener catches up.
   */
  const materializeSharedProject = useCallback(
    async (ownerID: string, rawProjectID: string): Promise<Project | null> => {
      const projectID = normalizeProjectID(rawProjectID)
      const snapshot = await getDocFromServer(
        doc(db, "users", ownerID, "projects", projectID),
      )
      if (!snapshot.exists()) return null
      const decoded = await decodeProject(snapshot.data())
      if (!decoded) return null
      const project = { ...decoded, ownerID }
      preloadProjectCover(project.coverStoragePath)
      setSharedProjects((prev) => new Map(prev).set(projectID, project))
      return playableShared(project)
    },
    [],
  )

  // Own projects.
  useEffect(() => {
    if (!user || !isSignedIn) {
      setOwnProjects([])
      setLoading(true)
      return
    }
    const projectsQuery = query(
      collection(db, "users", user.uid, "projects"),
      orderBy("updatedDate", "desc"),
    )
    let cancelled = false
    const unsubscribe = onSnapshot(
      projectsQuery,
      async (snapshot) => {
        const decoded = await Promise.all(snapshot.docs.map((d) => decodeProject(d.data())))
        if (cancelled) return
        const projects = decoded.filter((p): p is Project => p !== null)
        projects.forEach((project) => preloadProjectCover(project.coverStoragePath))
        setOwnProjects(projects)
        setLoading(false)
      },
      (error) => {
        console.error("projects listener failed", error)
        if (!cancelled) setLoading(false)
      },
    )
    return () => {
      cancelled = true
      unsubscribe()
    }
  }, [user, isSignedIn])

  // Accepted shared projects: refs live at users/{uid}/private/sharedProjects,
  // each ref gets its own listener on the owner's project document.
  const sharedListeners = useRef(new Map<string, () => void>())
  useEffect(() => {
    const listeners = sharedListeners.current
    const clearAll = () => {
      listeners.forEach((unsubscribe) => unsubscribe())
      listeners.clear()
      setSharedProjects(new Map())
    }
    if (!user || !isSignedIn) {
      clearAll()
      return
    }
    const uid = user.uid
    const unsubscribeRefs = onSnapshot(
      sharedRefsDoc(uid),
      (snapshot) => {
        const refs = (snapshot.data()?.refs ?? {}) as Record<string, { ownerID?: string }>
        const wanted = new Map<string, string>()
        for (const [projectID, ref] of Object.entries(refs)) {
          if (ref?.ownerID) wanted.set(normalizeProjectID(projectID), ref.ownerID)
        }
        // Drop listeners for removed refs.
        for (const [projectID, unsubscribe] of listeners) {
          if (!wanted.has(projectID)) {
            unsubscribe()
            listeners.delete(projectID)
            setSharedProjects((prev) => {
              const next = new Map(prev)
              next.delete(projectID)
              return next
            })
          }
        }
        // Subscribe to new refs.
        for (const [projectID, ownerID] of wanted) {
          if (listeners.has(projectID)) continue
          const unsubscribe = onSnapshot(
            doc(db, "users", ownerID, "projects", projectID),
            async (projectSnapshot) => {
              if (!projectSnapshot.exists()) {
                // Owner deleted the project — drop it and clean the ref.
                setSharedProjects((prev) => {
                  const next = new Map(prev)
                  next.delete(projectID)
                  return next
                })
                void removeSharedRef(uid, projectID)
                return
              }
              const decoded = await decodeProject(projectSnapshot.data())
              if (!decoded) return
              const project = { ...decoded, ownerID }
              preloadProjectCover(project.coverStoragePath)
              setSharedProjects((prev) => new Map(prev).set(projectID, project))
            },
            (error) => {
              // Never delete the authoritative shared reference because a
              // listener failed: offline/transient errors are not revocations.
              // Real revocations are removed by the server-side invitee-delete
              // trigger and arrive through the shared-refs listener.
              console.error(`shared project listener failed for ${projectID}`, error)
              listeners.delete(projectID)
            },
          )
          listeners.set(projectID, unsubscribe)
        }
      },
      () => {},
    )
    return () => {
      unsubscribeRefs()
      clearAll()
    }
  }, [user, isSignedIn])

  // Re-derives shared projects whenever a local-only version pick changes.
  const versionSelectionRevision = useSyncExternalStore(
    subscribeSharedVersionSelection,
    sharedVersionSelectionRevision,
  )

  const projects = useMemo(() => {
    void versionSelectionRevision
    const merged = [...ownProjects, ...[...sharedProjects.values()].map(playableShared)]
    merged.sort((a, b) => b.updatedDate.getTime() - a.updatedDate.getTime())
    return merged
  }, [ownProjects, sharedProjects, versionSelectionRevision])

  return (
    <ProjectsContext.Provider value={{ projects, loading, materializeSharedProject }}>
      {children}
    </ProjectsContext.Provider>
  )
}

export function useProjects(): ProjectsContextValue {
  return useContext(ProjectsContext)
}

export function useProject(projectID: string | undefined): Project | undefined {
  const { projects } = useProjects()
  if (!projectID) return undefined
  const normalizedID = normalizeProjectID(projectID)
  return projects.find((project) => normalizeProjectID(project.id) === normalizedID)
}
