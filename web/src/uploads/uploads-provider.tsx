import { Timestamp, doc, setDoc, updateDoc } from "firebase/firestore"
import { ref as storageRef, uploadBytesResumable } from "firebase/storage"
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { toast } from "sonner"
import { useAuth } from "@/hooks/use-auth"
import { PLAN_TIERS, effectiveTier, usePlan } from "@/hooks/use-plan"
import { useProjects } from "@/hooks/use-projects"
import { encodeProject, encodeTrack } from "@/lib/codec"
import { db, storage } from "@/lib/firebase"
import { analyzeAudioFile } from "@/lib/waveform-analyzer"
import { randomGradient, type Project, type Track } from "@/lib/types"

export type ImportTarget = { kind: "existing"; projectID: string } | { kind: "new" }

export interface UploadItem {
  id: string
  title: string
  status: "analyzing" | "uploading" | "saving" | "done" | "error"
  /** Upload progress 0…1 (only meaningful while `uploading`). */
  progress: number
}

interface UploadsContextValue {
  uploads: UploadItem[]
  isImporting: boolean
  /** Imports audio files; resolves to the destination project ID (or null on failure). */
  importFiles: (files: File[], target: ImportTarget) => Promise<string | null>
}

const UploadsContext = createContext<UploadsContextValue | null>(null)

const AUDIO_EXTENSIONS = new Set(["mp3", "m4a", "wav", "aiff", "aif", "flac", "aac"])

function mimeType(ext: string): string {
  switch (ext) {
    case "mp3":
      return "audio/mpeg"
    case "wav":
      return "audio/wav"
    case "aiff":
    case "aif":
      return "audio/aiff"
    case "m4a":
    case "aac":
      return "audio/mp4"
    case "flac":
      return "audio/flac"
    default:
      return "application/octet-stream"
  }
}

function uuid(): string {
  return crypto.randomUUID().toUpperCase()
}

export function UploadsProvider({ children }: { children: ReactNode }) {
  const { user, isSignedIn } = useAuth()
  const { projects } = useProjects()
  const plan = usePlan()
  const [uploads, setUploads] = useState<UploadItem[]>([])
  const [isImporting, setIsImporting] = useState(false)

  // Latest state refs so the async pipeline reads fresh data at write time.
  const projectsRef = useRef(projects)
  projectsRef.current = projects
  const planRef = useRef(plan)
  planRef.current = plan

  // Sweep finished rows off the card after a short delay.
  useEffect(() => {
    if (!uploads.some((u) => u.status === "done" || u.status === "error")) return
    const timer = setTimeout(() => {
      setUploads((prev) => prev.filter((u) => u.status !== "done" && u.status !== "error"))
    }, 3200)
    return () => clearTimeout(timer)
  }, [uploads])

  const patchItem = (id: string, patch: Partial<UploadItem>) => {
    setUploads((prev) => prev.map((u) => (u.id === id ? { ...u, ...patch } : u)))
  }

  const importFiles = useCallback(
    async (files: File[], target: ImportTarget): Promise<string | null> => {
      if (!user || !isSignedIn) return null

      const audioFiles = files.filter((file) => {
        const ext = file.name.split(".").pop()?.toLowerCase() ?? ""
        return AUDIO_EXTENSIONS.has(ext) || file.type.startsWith("audio/")
      })
      if (audioFiles.length === 0) {
        toast("No audio files found. Supported: mp3, m4a, wav, aiff, flac, aac.")
        return null
      }

      // Plan storage gate, mirroring the iOS `canStore(additionalBytes:)`.
      const limit = PLAN_TIERS[effectiveTier(planRef.current)].storageLimitBytes
      if (limit !== null) {
        const used = projectsRef.current
          .filter((p) => !p.ownerID)
          .flatMap((p) => p.tracks)
          .reduce(
            (total, t) =>
              total +
              (t.versions.length === 0
                ? t.fileSize
                : t.versions.reduce((sum, v) => sum + v.fileSize, 0)),
            0,
          )
        const incoming = audioFiles.reduce((sum, f) => sum + f.size, 0)
        if (used + incoming > limit) {
          toast("Not enough storage on your plan. Free up space or upgrade to continue.")
          return null
        }
      }

      setIsImporting(true)
      const newTracks: Track[] = []
      let failures = 0

      try {
        for (const file of audioFiles) {
          const trackID = uuid()
          const ext = (file.name.split(".").pop()?.toLowerCase() || "m4a").replace(/[^a-z0-9]/g, "")
          const rawTitle = file.name.replace(/\.[^.]+$/, "")
          const title = rawTitle || "Untitled"
          const itemID = trackID

          setUploads((prev) => [
            ...prev,
            { id: itemID, title, status: "analyzing", progress: 0 },
          ])

          try {
            // 1. Analyze — same 200-bar RMS envelope the iOS import computes.
            const { duration, waveform } = await analyzeAudioFile(file)

            // 2. Upload to the same flat path iOS uses for fresh imports.
            patchItem(itemID, { status: "uploading" })
            const storagePath = `users/${user.uid}/audio/${trackID.toLowerCase()}.${ext}`
            const task = uploadBytesResumable(storageRef(storage, storagePath), file, {
              contentType: mimeType(ext),
            })
            await new Promise<void>((resolve, reject) => {
              task.on(
                "state_changed",
                (snapshot) => {
                  patchItem(itemID, {
                    progress: snapshot.totalBytes > 0 ? snapshot.bytesTransferred / snapshot.totalBytes : 0,
                  })
                },
                reject,
                resolve,
              )
            })

            // 3. Track shaped exactly like an iOS import (legacy single-file track).
            newTracks.push({
              id: trackID,
              title,
              fileName: `${uuid()}.${ext}`,
              fileSize: file.size,
              duration,
              addedDate: new Date(),
              waveform: waveform.length > 0 ? waveform : undefined,
              storagePath,
              notes: "",
              versions: [],
            })
            patchItem(itemID, { status: "saving", progress: 1 })
          } catch (error) {
            console.error("import failed for", file.name, error)
            failures++
            patchItem(itemID, { status: "error" })
          }
        }

        if (newTracks.length === 0) {
          toast("Couldn't import these files. Please try again.")
          return null
        }

        // 4. Single Firestore write for the whole batch (like the iOS `addTracks`).
        let destinationID: string
        if (target.kind === "existing") {
          const project = projectsRef.current.find((p) => p.id === target.projectID)
          if (!project) {
            toast("Project not found.")
            return null
          }
          destinationID = project.id
          const tracks = await Promise.all([...project.tracks, ...newTracks].map(encodeTrack))
          await updateDoc(doc(db, "users", user.uid, "projects", project.id), {
            tracks,
            updatedDate: Timestamp.now(),
          })
        } else {
          const project: Project = {
            id: uuid(),
            name: "untitled project",
            gradient: randomGradient(),
            tracks: newTracks,
            createdDate: new Date(),
            updatedDate: new Date(),
          }
          destinationID = project.id
          await setDoc(
            doc(db, "users", user.uid, "projects", project.id),
            await encodeProject(project),
          )
        }

        setUploads((prev) =>
          prev.map((u) => (u.status === "saving" ? { ...u, status: "done" } : u)),
        )
        if (failures > 0) {
          toast(`${failures} ${failures === 1 ? "file" : "files"} couldn't be imported.`)
        }
        return destinationID
      } catch (error) {
        console.error("import batch failed", error)
        toast("Import failed. Check your connection and try again.")
        setUploads((prev) =>
          prev.map((u) => (u.status === "saving" ? { ...u, status: "error" } : u)),
        )
        return null
      } finally {
        setIsImporting(false)
      }
    },
    [user, isSignedIn],
  )

  return (
    <UploadsContext.Provider value={{ uploads, isImporting, importFiles }}>
      {children}
    </UploadsContext.Provider>
  )
}

export function useUploads(): UploadsContextValue {
  const context = useContext(UploadsContext)
  if (!context) throw new Error("useUploads must be used within UploadsProvider")
  return context
}
