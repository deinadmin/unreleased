import { Timestamp, deleteField, doc, setDoc, updateDoc } from "firebase/firestore"
import { deleteObject, ref as storageRef, uploadBytes } from "firebase/storage"
import { accentHexFromGradient, accentHexFromImage, gradientHexPairFromImage } from "./accent-color"
import { encodeGradient, encodeProject, encodeTrack } from "./codec"
import { db, storage } from "./firebase"
import type { GradientTheme, Project } from "./types"

/** Firestore edits for the user's own projects, mirroring the iOS `EditProjectSheet.save()`. */

const projectDoc = (uid: string, projectID: string) => doc(db, "users", uid, "projects", projectID)

/** Creates an empty project with a title and preset gradient cover. */
export async function createProject(
  uid: string,
  rawName: string,
  gradient: GradientTheme,
): Promise<Project> {
  const project: Project = {
    id: crypto.randomUUID().toUpperCase(),
    name: rawName.trim() || "untitled project",
    gradient,
    accentColorHex: accentHexFromGradient(gradient),
    tracks: [],
    createdDate: new Date(),
    updatedDate: new Date(),
  }
  await setDoc(projectDoc(uid, project.id), await encodeProject(project))
  return project
}

export async function updateProjectName(uid: string, project: Project, rawName: string): Promise<void> {
  const trimmed = rawName.trim()
  const name = trimmed || "untitled project"
  if (name === project.name) return
  await updateDoc(projectDoc(uid, project.id), {
    name,
    updatedDate: Timestamp.now(),
  })
}

/** Saves the notes for a single track by rewriting the embedded tracks array. */
export async function updateTrackNotes(
  uid: string,
  project: Project,
  trackID: string,
  notes: string,
): Promise<void> {
  const current = project.tracks.find((t) => t.id === trackID)
  if (!current || current.notes === notes) return
  const tracks = await Promise.all(
    project.tracks.map((t) => encodeTrack(t.id === trackID ? { ...t, notes } : t)),
  )
  await updateDoc(projectDoc(uid, project.id), {
    tracks,
    updatedDate: Timestamp.now(),
  })
}

/** Removes a track from the project and cleans up its audio files. */
export async function deleteTrack(uid: string, project: Project, trackID: string): Promise<void> {
  const target = project.tracks.find((t) => t.id === trackID)
  if (!target) return
  const tracks = await Promise.all(
    project.tracks.filter((t) => t.id !== trackID).map(encodeTrack),
  )
  await updateDoc(projectDoc(uid, project.id), {
    tracks,
    updatedDate: Timestamp.now(),
  })
  // Best-effort cleanup of the cloud audio files.
  const paths = new Set<string>()
  if (target.storagePath) paths.add(target.storagePath)
  for (const version of target.versions) {
    if (version.storagePath) paths.add(version.storagePath)
  }
  for (const path of paths) {
    deleteObject(storageRef(storage, path)).catch(() => {})
  }
}

/** Switches the cover to a preset gradient (clears any cover image, like iOS). */
export async function setProjectGradient(
  uid: string,
  project: Project,
  gradient: GradientTheme,
): Promise<void> {
  await updateDoc(projectDoc(uid, project.id), {
    gradient: encodeGradient(gradient),
    accentColorHex: accentHexFromGradient(gradient),
    coverGradientColors: deleteField(),
    coverStoragePath: deleteField(),
    updatedDate: Timestamp.now(),
  })
  // Best-effort cleanup of the replaced cloud cover.
  if (project.coverStoragePath) {
    deleteObject(storageRef(storage, project.coverStoragePath)).catch(() => {})
  }
}

/**
 * Sets a cover image: center-crops to a square JPEG, extracts the accent and
 * vinyl gradient colors like iOS, uploads to `users/{uid}/covers/`, then
 * updates the project document.
 */
export async function setProjectCoverImage(
  uid: string,
  project: Project,
  file: File,
): Promise<void> {
  const bitmap = await createImageBitmap(file)
  try {
    const blob = await squareJpeg(bitmap)
    const accentColorHex = accentHexFromImage(bitmap)
    const coverGradientColors = gradientHexPairFromImage(bitmap)

    // Same naming convention as the iOS `saveCoverImage`.
    const fileName = `${project.id}-${Math.floor(Date.now() / 1000)}.jpg`
    const storagePath = `users/${uid}/covers/${fileName}`
    await uploadBytes(storageRef(storage, storagePath), blob, { contentType: "image/jpeg" })

    await updateDoc(projectDoc(uid, project.id), {
      coverStoragePath: storagePath,
      accentColorHex,
      coverGradientColors,
      updatedDate: Timestamp.now(),
    })

    if (project.coverStoragePath && project.coverStoragePath !== storagePath) {
      deleteObject(storageRef(storage, project.coverStoragePath)).catch(() => {})
    }
  } finally {
    bitmap.close()
  }
}

/** Center-crops to a square, capped at 1024px, encoded as JPEG (quality 0.85). */
async function squareJpeg(bitmap: ImageBitmap): Promise<Blob> {
  const side = Math.min(bitmap.width, bitmap.height)
  const target = Math.min(1024, side)
  const canvas = document.createElement("canvas")
  canvas.width = target
  canvas.height = target
  const ctx = canvas.getContext("2d")
  if (!ctx) throw new Error("canvas unavailable")
  ctx.drawImage(
    bitmap,
    (bitmap.width - side) / 2,
    (bitmap.height - side) / 2,
    side,
    side,
    0,
    0,
    target,
    target,
  )
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error("jpeg encode failed"))),
      "image/jpeg",
      0.85,
    )
  })
}
