import { Timestamp, deleteDoc, doc, setDoc, updateDoc, writeBatch } from "firebase/firestore"
import { deleteObject, ref as storageRef } from "firebase/storage"
import { encodeTrack } from "./codec"
import { db, storage } from "./firebase"
import { invalidatePlayedTrackCache } from "./track-cache"
import type { Project, Track, TrackVersion } from "./types"
import {
  applyActiveVersionMetadata,
  displayedVersions,
  ensureVersionHistory,
  withSelectedVersion,
} from "./versions"

/**
 * Firestore edits for the versions of a track the user owns, mirroring the iOS
 * `ProjectStore` version API. Every mutation rewrites the project's embedded
 * `tracks` array, the same way the rest of the web edits do.
 */

/**
 * Version audio lives under its own object path so Cloud Storage rules can
 * enforce visibility per version (see `CloudPaths.versionAudioStoragePath`).
 */
export function versionAudioStoragePath(
  uid: string,
  versionID: string,
  fileExtension: string,
): string {
  return `users/${uid}/audio/versions/${versionID}/audio.${fileExtension}`
}

const versionAccessDoc = (uid: string, versionID: string) =>
  doc(db, "users", uid, "versionAccess", versionID)

/**
 * Owner-maintained visibility index the Storage rules read when a collaborator
 * or a share-link guest streams a version.
 */
async function writeVersionAccess(
  uid: string,
  projectID: string,
  versions: TrackVersion[],
): Promise<void> {
  if (versions.length === 0) return
  if (versions.length === 1) {
    await setDoc(
      versionAccessDoc(uid, versions[0].id),
      { projectID, isPublic: versions[0].isPublic },
      { merge: true },
    )
    return
  }
  const batch = writeBatch(db)
  for (const version of versions) {
    batch.set(
      versionAccessDoc(uid, version.id),
      { projectID, isPublic: version.isPublic },
      { merge: true },
    )
  }
  await batch.commit()
}

/** Best-effort removal of the visibility index for versions that no longer exist. */
export function deleteVersionAccess(uid: string, versionIDs: string[]): void {
  for (const versionID of new Set(versionIDs)) {
    deleteDoc(versionAccessDoc(uid, versionID)).catch(() => {})
  }
}

async function writeTrack(uid: string, project: Project, updated: Track): Promise<void> {
  const tracks = await Promise.all(
    project.tracks.map((track) => encodeTrack(track.id === updated.id ? updated : track)),
  )
  await updateDoc(doc(db, "users", uid, "projects", project.id), {
    tracks,
    updatedDate: Timestamp.now(),
  })
}

function trackIn(project: Project, trackID: string): Track | undefined {
  return project.tracks.find((track) => track.id === trackID)
}

/**
 * Inserts already-uploaded versions at the top of the history, newest last in
 * `added`, and makes the newest one active. Legacy single-file tracks gain
 * their implicit v1 first, so its audio keeps living at the flat storage path.
 */
export async function addVersions(
  uid: string,
  project: Project,
  trackID: string,
  added: TrackVersion[],
): Promise<void> {
  const current = trackIn(project, trackID)
  if (!current || added.length === 0) return
  const withHistory = ensureVersionHistory(current)
  const updated = applyActiveVersionMetadata({
    ...withHistory,
    versions: [...[...added].reverse(), ...withHistory.versions],
    activeVersionID: added[added.length - 1].id,
  })
  await writeVersionAccess(uid, project.id, updated.versions)
  await writeTrack(uid, project, updated)
}

export async function renameVersion(
  uid: string,
  project: Project,
  trackID: string,
  versionID: string,
  rawName: string,
): Promise<void> {
  const current = trackIn(project, trackID)
  if (!current) return
  const name = rawName.trim() || "Untitled Version"
  const withHistory = ensureVersionHistory(current)
  if (!withHistory.versions.some((version) => version.id === versionID)) return
  await writeTrack(uid, project, {
    ...withHistory,
    versions: withHistory.versions.map((version) =>
      version.id === versionID ? { ...version, name } : version,
    ),
  })
}

/** Makes a version the one the track (and therefore the player) uses. */
export async function selectVersion(
  uid: string,
  project: Project,
  trackID: string,
  versionID: string,
): Promise<void> {
  const current = trackIn(project, trackID)
  if (!current) return
  const updated = withSelectedVersion(current, versionID)
  if (updated.activeVersionID === current.activeVersionID) return
  await writeTrack(uid, project, updated)
}

/** Reorders the history; the first entry always holds the highest version number. */
export async function reorderVersions(
  uid: string,
  project: Project,
  trackID: string,
  orderedIDs: string[],
): Promise<void> {
  const current = trackIn(project, trackID)
  if (!current) return
  const withHistory = ensureVersionHistory(current)
  const versions = orderedIDs
    .map((id) => withHistory.versions.find((version) => version.id === id))
    .filter((version): version is TrackVersion => version !== undefined)
  if (versions.length !== withHistory.versions.length) return
  if (versions.every((version, index) => version.id === withHistory.versions[index].id)) return
  await writeTrack(uid, project, applyActiveVersionMetadata({ ...withHistory, versions }))
}

/** Toggles whether listeners on a shared project can see and stream a version. */
export async function setVersionPublic(
  uid: string,
  project: Project,
  trackID: string,
  versionID: string,
  isPublic: boolean,
): Promise<void> {
  const current = trackIn(project, trackID)
  if (!current) return
  const withHistory = ensureVersionHistory(current)
  const target = withHistory.versions.find((version) => version.id === versionID)
  if (!target || target.isPublic === isPublic) return
  // A track always keeps at least one version listeners can play.
  if (!isPublic && withHistory.versions.filter((version) => version.isPublic).length <= 1) return

  const updated = {
    ...withHistory,
    versions: withHistory.versions.map((version) =>
      version.id === versionID ? { ...version, isPublic } : version,
    ),
  }
  await writeTrack(uid, project, updated)
  await writeVersionAccess(uid, project.id, [{ ...target, isPublic }])
}

/** Removes a version and its cloud audio. The last remaining version can't be deleted. */
export async function deleteVersion(
  uid: string,
  project: Project,
  trackID: string,
  versionID: string,
): Promise<void> {
  const current = trackIn(project, trackID)
  if (!current) return
  const withHistory = ensureVersionHistory(current)
  if (withHistory.versions.length <= 1) return
  const deleted = withHistory.versions.find((version) => version.id === versionID)
  if (!deleted) return

  const versions = withHistory.versions.filter((version) => version.id !== versionID)
  const updated = applyActiveVersionMetadata({
    ...withHistory,
    versions,
    activeVersionID:
      withHistory.activeVersionID === versionID ? versions[0].id : withHistory.activeVersionID,
  })
  await writeTrack(uid, project, updated)

  // Best-effort cleanup of the cloud audio and its visibility index.
  if (deleted.storagePath) {
    invalidatePlayedTrackCache(deleted.storagePath)
    deleteObject(storageRef(storage, deleted.storagePath)).catch(() => {})
  }
  deleteVersionAccess(uid, [deleted.id])
}

/** Every version ID a track owns, including the implicit v1 of a legacy track. */
export function trackVersionIDs(track: Track): string[] {
  return displayedVersions(track).map((version) => version.id)
}
