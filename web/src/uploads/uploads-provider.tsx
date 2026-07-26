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
import { toast } from "@/lib/toast"
import { useAuth } from "@/hooks/use-auth"
import { PLAN_TIERS, effectiveTier, usePlan } from "@/hooks/use-plan"
import { useProjects } from "@/hooks/use-projects"
import { encodeProject, encodeTrack } from "@/lib/codec"
import { db, storage } from "@/lib/firebase"
import { addVersions, versionAudioStoragePath } from "@/lib/version-edits"
import { analyzeAudioFile } from "@/lib/waveform-analyzer"
import {
  randomGradient,
  trackStorageBytes,
  type Project,
  type Track,
  type TrackVersion,
} from "@/lib/types"

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
  /**
   * Imports audio files as new versions of an existing track, newest last.
   * Resolves to true once the track document has been updated.
   */
  importVersions: (files: File[], projectID: string, trackID: string) => Promise<boolean>
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

  /** Filters to audio files and applies the plan storage gate (iOS `canStore(additionalBytes:)`). */
  const acceptedFiles = useCallback((files: File[]): File[] | null => {
    const audioFiles = files.filter((file) => {
      const ext = file.name.split(".").pop()?.toLowerCase() ?? ""
      return AUDIO_EXTENSIONS.has(ext) || file.type.startsWith("audio/")
    })
    if (audioFiles.length === 0) {
      toast("No audio files found. Supported: mp3, m4a, wav, aiff, flac, aac.")
      return null
    }

    const limit = PLAN_TIERS[effectiveTier(planRef.current)].storageLimitBytes
    if (limit !== null) {
      const used = projectsRef.current
        .filter((p) => !p.ownerID)
        .flatMap((p) => p.tracks)
        .reduce((total, t) => total + trackStorageBytes(t), 0)
      const incoming = audioFiles.reduce((sum, f) => sum + f.size, 0)
      if (used + incoming > limit) {
        toast("Not enough storage on your plan. Free up space or upgrade to continue.")
        return null
      }
    }
    return audioFiles
  }, [])

  /** Analyzes a file and uploads it to `storagePath`, reporting progress on the card. */
  const analyzeAndUpload = useCallback(
    async (file: File, itemID: string, storagePath: string, ext: string) => {
      // Same 200-bar RMS envelope the iOS import computes.
      const { duration, waveform } = await analyzeAudioFile(file)

      patchItem(itemID, { status: "uploading" })
      const task = uploadBytesResumable(storageRef(storage, storagePath), file, {
        contentType: mimeType(ext),
      })
      await new Promise<void>((resolve, reject) => {
        task.on(
          "state_changed",
          (snapshot) => {
            patchItem(itemID, {
              progress:
                snapshot.totalBytes > 0 ? snapshot.bytesTransferred / snapshot.totalBytes : 0,
            })
          },
          reject,
          resolve,
        )
      })
      patchItem(itemID, { status: "saving", progress: 1 })
      return { duration, waveform }
    },
    [],
  )

  const importFiles = useCallback(
    async (files: File[], target: ImportTarget): Promise<string | null> => {
      if (!user || !isSignedIn) return null

      const audioFiles = acceptedFiles(files)
      if (!audioFiles) return null

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
            // Upload to the same flat path iOS uses for fresh imports.
            const storagePath = `users/${user.uid}/audio/${trackID.toLowerCase()}.${ext}`
            const { duration, waveform } = await analyzeAndUpload(file, itemID, storagePath, ext)

            // Track shaped exactly like an iOS import (legacy single-file track).
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

        // Single Firestore write for the whole batch (like the iOS `addTracks`).
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
    [user, isSignedIn, acceptedFiles, analyzeAndUpload],
  )

  /**
   * Adds new versions to an existing track. Version audio goes to its own
   * object path so the Storage rules can enforce per-version visibility.
   */
  const importVersions = useCallback(
    async (files: File[], projectID: string, trackID: string): Promise<boolean> => {
      if (!user || !isSignedIn) return false

      const audioFiles = acceptedFiles(files)
      if (!audioFiles) return false

      setIsImporting(true)
      const added: TrackVersion[] = []
      let failures = 0

      try {
        for (const file of audioFiles) {
          const versionID = uuid()
          const ext = (file.name.split(".").pop()?.toLowerCase() || "m4a").replace(/[^a-z0-9]/g, "")
          const title = file.name.replace(/\.[^.]+$/, "") || "Untitled"

          setUploads((prev) => [...prev, { id: versionID, title, status: "analyzing", progress: 0 }])

          try {
            const storagePath = versionAudioStoragePath(user.uid, versionID, ext)
            const { duration, waveform } = await analyzeAndUpload(file, versionID, storagePath, ext)
            added.push({
              id: versionID,
              name: title,
              fileName: `${uuid()}.${ext}`,
              fileSize: file.size,
              duration,
              addedDate: new Date(),
              waveform: waveform.length > 0 ? waveform : undefined,
              storagePath,
              isPublic: true,
            })
          } catch (error) {
            console.error("version import failed for", file.name, error)
            failures++
            patchItem(versionID, { status: "error" })
          }
        }

        if (added.length === 0) {
          toast("Couldn't add this version. Please try again.")
          return false
        }

        const project = projectsRef.current.find((p) => p.id === projectID)
        if (!project || project.ownerID) {
          toast("Project not found.")
          return false
        }
        await addVersions(user.uid, project, trackID, added)

        setUploads((prev) => prev.map((u) => (u.status === "saving" ? { ...u, status: "done" } : u)))
        if (failures > 0) {
          toast(`${failures} ${failures === 1 ? "file" : "files"} couldn't be added.`)
        }
        return true
      } catch (error) {
        console.error("version import failed", error)
        toast("Couldn't add this version. Check your connection and try again.")
        setUploads((prev) =>
          prev.map((u) => (u.status === "saving" ? { ...u, status: "error" } : u)),
        )
        return false
      } finally {
        setIsImporting(false)
      }
    },
    [user, isSignedIn, acceptedFiles, analyzeAndUpload],
  )

  return (
    <UploadsContext.Provider value={{ uploads, isImporting, importFiles, importVersions }}>
      {children}
    </UploadsContext.Provider>
  )
}

export function useUploads(): UploadsContextValue {
  const context = useContext(UploadsContext)
  if (!context) throw new Error("useUploads must be used within UploadsProvider")
  return context
}
