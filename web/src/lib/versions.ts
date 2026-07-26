import type { Track, TrackVersion } from "./types"

/**
 * Track version helpers mirroring the iOS `Track` version API. The newest
 * version is always stored first, and an empty `versions` array is a legacy
 * single-file track that is surfaced as an implicit v1.
 */

export function displayedVersions(track: Track): TrackVersion[] {
  if (track.versions.length > 0) return track.versions
  return [
    {
      id: track.id,
      name: track.title,
      fileName: track.fileName,
      fileSize: track.fileSize,
      duration: track.duration,
      addedDate: track.addedDate,
      waveform: track.waveform,
      storagePath: track.storagePath,
      isPublic: true,
    },
  ]
}

export function resolvedActiveVersionID(track: Track): string {
  return track.activeVersionID ?? displayedVersions(track)[0]?.id ?? track.id
}

export function hasMultipleVersions(track: Track): boolean {
  return displayedVersions(track).length > 1
}

/** 1-based version number counting up from the oldest version. */
export function versionNumber(track: Track, versionID: string): number | null {
  const versions = displayedVersions(track)
  const index = versions.findIndex((version) => version.id === versionID)
  return index === -1 ? null : versions.length - index
}

export function activeVersionNumber(track: Track): number | null {
  return versionNumber(track, resolvedActiveVersionID(track))
}

/** Listeners on a shared project only ever see the versions the owner made public. */
export function visibleVersions(track: Track, isShared: boolean): TrackVersion[] {
  const versions = displayedVersions(track)
  return isShared ? versions.filter((version) => version.isPublic) : versions
}

export function versionDisplayName(track: Track, version: TrackVersion): string {
  const storedName = version.name?.trim()
  if (storedName) return storedName
  const versions = displayedVersions(track)
  // The oldest version is the original import, so it carries the track title.
  if (versions[versions.length - 1]?.id === version.id) return track.title
  const fileTitle = version.fileName.replace(/\.[^./]+$/, "")
  return fileTitle || "Untitled Version"
}

/** Materializes the implicit v1 of a legacy single-file track. */
export function ensureVersionHistory(track: Track): Track {
  if (track.versions.length > 0) {
    if (track.activeVersionID) return track
    return { ...track, activeVersionID: track.versions[0].id }
  }
  const original = { ...displayedVersions(track)[0], name: track.title }
  return { ...track, versions: [original], activeVersionID: original.id }
}

/** Surfaces the active version's file metadata at the track level. */
export function applyActiveVersionMetadata(track: Track): Track {
  if (track.versions.length === 0) return track
  const active =
    track.versions.find((version) => version.id === track.activeVersionID) ?? track.versions[0]
  return {
    ...track,
    activeVersionID: active.id,
    fileName: active.fileName,
    fileSize: active.fileSize,
    duration: active.duration,
    waveform: active.waveform,
    storagePath: active.storagePath,
  }
}

/** Makes `versionID` active, materializing the version history when needed. */
export function withSelectedVersion(track: Track, versionID: string): Track {
  const withHistory = ensureVersionHistory(track)
  if (!withHistory.versions.some((version) => version.id === versionID)) return track
  return applyActiveVersionMetadata({ ...withHistory, activeVersionID: versionID })
}

/** Mirrors the SwiftUI `move(fromOffsets:toOffset:)` index convention. */
export function movedVersions(
  versions: TrackVersion[],
  sourceIndex: number,
  destination: number,
): TrackVersion[] {
  const next = [...versions]
  const [moved] = next.splice(sourceIndex, 1)
  if (!moved) return versions
  next.splice(destination > sourceIndex ? destination - 1 : destination, 0, moved)
  return next
}
