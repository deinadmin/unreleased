import { collection, doc, onSnapshot, orderBy, query } from "firebase/firestore"
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { useAuth } from "@/hooks/use-auth"
import { decodeProject } from "@/lib/codec"
import { db } from "@/lib/firebase"
import { normalizeProjectID, removeSharedRef, sharedRefsDoc } from "@/lib/invites"
import { sharedPlayableProject, type Project } from "@/lib/types"

interface ProjectsContextValue {
  projects: Project[]
  loading: boolean
}

const ProjectsContext = createContext<ProjectsContextValue>({ projects: [], loading: true })

export function ProjectsProvider({ children }: { children: ReactNode }) {
  const { user, isSignedIn } = useAuth()
  const [ownProjects, setOwnProjects] = useState<Project[]>([])
  const [sharedProjects, setSharedProjects] = useState<Map<string, Project>>(new Map())
  const [loading, setLoading] = useState(true)

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
        setOwnProjects(decoded.filter((p): p is Project => p !== null))
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
              const project = sharedPlayableProject({ ...decoded, ownerID })
              setSharedProjects((prev) => new Map(prev).set(projectID, project))
            },
            () => {
              // Permission denied — owner revoked access. Remove locally.
              setSharedProjects((prev) => {
                const next = new Map(prev)
                next.delete(projectID)
                return next
              })
              listeners.get(projectID)?.()
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

  const projects = useMemo(() => {
    const merged = [...ownProjects, ...sharedProjects.values()]
    merged.sort((a, b) => b.updatedDate.getTime() - a.updatedDate.getTime())
    return merged
  }, [ownProjects, sharedProjects])

  return (
    <ProjectsContext.Provider value={{ projects, loading }}>{children}</ProjectsContext.Provider>
  )
}

export function useProjects(): ProjectsContextValue {
  return useContext(ProjectsContext)
}

export function useProject(projectID: string | undefined): Project | undefined {
  const { projects } = useProjects()
  return projects.find((p) => p.id === projectID)
}
