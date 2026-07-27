import {
  Timestamp,
  collection,
  deleteField,
  doc,
  getDocs,
  setDoc,
  updateDoc,
  writeBatch,
} from "firebase/firestore"
import { deleteObject, ref as storageRef, uploadBytes } from "firebase/storage"
import { accentHexFromGradient, accentHexFromImage, gradientHexPairFromImage } from "./accent-color"
import { encodeGradient, encodeProject, encodeTrack } from "./codec"
import { db, storage } from "./firebase"
import { refreshPreviewIfExists } from "./invites"
import { compressedSquareJpeg, COVER_PHOTO_LIMITS } from "./photo-compression"
import {
  cacheUploadedProjectCover,
  invalidateProjectCover,
} from "./project-cover-cache"
import { invalidatePlayedTrackCache } from "./track-cache"
import type { GradientTheme, Project, Track } from "./types"
import { deleteVersionAccess } from "./version-edits"

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
  await refreshPreviewIfExists({ ...project, name }, uid)
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

/** Renames a single track by rewriting the project's embedded tracks array. */
export async function updateTrackTitle(
  uid: string,
  project: Project,
  trackID: string,
  rawTitle: string,
): Promise<void> {
  const title = rawTitle.trim()
  const current = project.tracks.find((track) => track.id === trackID)
  if (!title || !current || current.title === title) return
  const tracks = await Promise.all(
    project.tracks.map((track) =>
      encodeTrack(track.id === trackID ? { ...track, title } : track),
    ),
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
  // Best-effort cleanup of the cloud audio files and version visibility index.
  deleteAudioObjects(audioPaths(target))
  deleteVersionAccess(uid, target.versions.map((v) => v.id))
}

/** A track queued for deletion, identified by the project that holds it. */
export interface TrackLocation {
  projectID: string
  trackID: string
}

/**
 * Removes several tracks with one write per affected project, mirroring the iOS
 * `ProjectStore.deleteOwnedTracks`. Shared projects are skipped as a second
 * layer of protection beyond the filtering done by the deletion screen.
 */
export async function deleteTracks(
  uid: string,
  projects: Project[],
  locations: TrackLocation[],
): Promise<void> {
  const trackIDsByProject = new Map<string, Set<string>>()
  for (const { projectID, trackID } of locations) {
    const ids = trackIDsByProject.get(projectID) ?? new Set<string>()
    ids.add(trackID)
    trackIDsByProject.set(projectID, ids)
  }

  const removedPaths: string[] = []
  await Promise.all(
    projects.map(async (project) => {
      const trackIDs = trackIDsByProject.get(project.id)
      if (project.ownerID || !trackIDs) return
      const removed = project.tracks.filter((t) => trackIDs.has(t.id))
      if (removed.length === 0) return
      const tracks = await Promise.all(
        project.tracks.filter((t) => !trackIDs.has(t.id)).map(encodeTrack),
      )
      await updateDoc(projectDoc(uid, project.id), {
        tracks,
        updatedDate: Timestamp.now(),
      })
      removedPaths.push(...removed.flatMap(audioPaths))
      deleteVersionAccess(uid, removed.flatMap((t) => t.versions.map((v) => v.id)))
    }),
  )
  // Best-effort cleanup of the cloud audio files.
  deleteAudioObjects(removedPaths)
}

/** Every cloud audio object a track owns: its own file plus each version. */
function audioPaths(track: Track): string[] {
  return [track.storagePath, ...track.versions.map((v) => v.storagePath)].filter(
    (path): path is string => Boolean(path),
  )
}

function deleteAudioObjects(paths: string[]): void {
  for (const path of new Set(paths)) {
    invalidatePlayedTrackCache(path)
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
  await refreshPreviewIfExists(
    {
      ...project,
      gradient,
      accentColorHex: accentHexFromGradient(gradient),
      coverGradientColors: undefined,
      coverStoragePath: undefined,
    },
    uid,
  )
  // Best-effort cleanup of the replaced cloud cover.
  if (project.coverStoragePath) {
    await invalidateProjectCover(project.coverStoragePath)
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
  const bitmap = await createImageBitmap(file, { imageOrientation: "from-image" })
  try {
    const blob = await compressedSquareJpeg(bitmap, COVER_PHOTO_LIMITS)
    const accentColorHex = accentHexFromImage(bitmap)
    const coverGradientColors = gradientHexPairFromImage(bitmap)

    // A unique immutable path is what makes long-lived browser caching safe.
    const fileName = `${project.id}-${Date.now()}-${crypto.randomUUID()}.jpg`
    const storagePath = `users/${uid}/covers/${fileName}`
    await uploadBytes(storageRef(storage, storagePath), blob, {
      contentType: "image/jpeg",
      cacheControl: "public,max-age=31536000,immutable",
    })

    try {
      // Seed the exact uploaded bytes before publishing the new path. When the
      // Firestore listener fires, every cover can render without downloading.
      await cacheUploadedProjectCover(storagePath, blob)
      await updateDoc(projectDoc(uid, project.id), {
        coverStoragePath: storagePath,
        accentColorHex,
        coverGradientColors,
        updatedDate: Timestamp.now(),
      })
      await refreshPreviewIfExists(
        { ...project, coverStoragePath: storagePath, accentColorHex, coverGradientColors },
        uid,
      )
    } catch (error) {
      await invalidateProjectCover(storagePath)
      deleteObject(storageRef(storage, storagePath)).catch(() => {})
      throw error
    }

    if (project.coverStoragePath && project.coverStoragePath !== storagePath) {
      await invalidateProjectCover(project.coverStoragePath)
      deleteObject(storageRef(storage, project.coverStoragePath)).catch(() => {})
    }
  } finally {
    bitmap.close()
  }
}

/**
 * Permanently removes an owned project and its related cloud records. Storage
 * cleanup is best-effort after the authoritative Firestore delete succeeds.
 */
export async function deleteProject(uid: string, project: Project): Promise<void> {
  const projectRef = projectDoc(uid, project.id)
  const [invitees, pendingInvites] = await Promise.all([
    getDocs(collection(projectRef, "invitees")),
    getDocs(collection(projectRef, "pendingInvites")),
  ])

  const batch = writeBatch(db)
  invitees.forEach((snapshot) => batch.delete(snapshot.ref))
  pendingInvites.forEach((snapshot) => batch.delete(snapshot.ref))
  batch.delete(doc(db, "users", uid, "projectPreviews", project.id))

  for (const track of project.tracks) {
    const versionIDs = track.versions.length > 0
      ? track.versions.map((version) => version.id)
      : [track.id]
    for (const versionID of versionIDs) {
      batch.delete(doc(db, "users", uid, "versionAccess", versionID))
    }
  }
  batch.delete(projectRef)
  await batch.commit()

  const storagePaths = new Set<string>()
  if (project.coverStoragePath) {
    storagePaths.add(project.coverStoragePath)
    await invalidateProjectCover(project.coverStoragePath)
  }
  for (const track of project.tracks) {
    if (track.storagePath) storagePaths.add(track.storagePath)
    for (const version of track.versions) {
      if (version.storagePath) storagePaths.add(version.storagePath)
    }
  }
  for (const storagePath of storagePaths) {
    invalidatePlayedTrackCache(storagePath)
  }
  await Promise.allSettled(
    [...storagePaths].map((path) => deleteObject(storageRef(storage, path))),
  )
}
