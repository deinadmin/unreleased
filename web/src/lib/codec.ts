import { Timestamp, type DocumentData } from "firebase/firestore"
import type { GradientTheme, Project, Track, TrackVersion } from "./types"
import { decodeWaveform, encodeWaveform } from "./waveform"

/** Mirrors the iOS `FirestoreProjectCodec.decode`. */
export async function decodeProject(data: DocumentData): Promise<Project | null> {
  const gradient = decodeGradient(data.gradient)
  if (typeof data.id !== "string" || typeof data.name !== "string" || !gradient) return null

  const trackMaps: DocumentData[] = Array.isArray(data.tracks) ? data.tracks : []
  const tracks = (await Promise.all(trackMaps.map(decodeTrack))).filter(
    (t): t is Track => t !== null,
  )

  return {
    id: data.id,
    name: data.name,
    gradient,
    coverStoragePath: asString(data.coverStoragePath),
    accentColorHex: asString(data.accentColorHex),
    coverGradientColors: Array.isArray(data.coverGradientColors)
      ? data.coverGradientColors
      : undefined,
    tracks,
    createdDate: asDate(data.createdDate) ?? new Date(),
    updatedDate: asDate(data.updatedDate) ?? new Date(),
    ownerUsername: asString(data.ownerUsername),
  }
}

async function decodeTrack(data: DocumentData): Promise<Track | null> {
  if (typeof data.id !== "string" || typeof data.title !== "string") return null
  const versions = (
    await Promise.all((Array.isArray(data.versions) ? data.versions : []).map(decodeVersion))
  ).filter((v): v is TrackVersion => v !== null)

  const track: Track = {
    id: data.id,
    title: data.title,
    fileName: asString(data.fileName) ?? "",
    fileSize: asNumber(data.fileSize),
    duration: asNumber(data.duration),
    addedDate: asDate(data.addedDate) ?? new Date(),
    waveform: typeof data.waveform === "string" ? await decodeWaveform(data.waveform) : undefined,
    storagePath: asString(data.storagePath),
    notes: asString(data.notes) ?? "",
    versions,
    activeVersionID: asString(data.activeVersionID),
  }

  // Mirror the iOS `applyActiveVersionMetadata`: the active version's file
  // metadata is surfaced at the track level.
  if (versions.length > 0) {
    const active = versions.find((v) => v.id === track.activeVersionID) ?? versions[0]
    track.activeVersionID = active.id
    track.fileName = active.fileName
    track.fileSize = active.fileSize
    track.duration = active.duration
    track.waveform = active.waveform
    track.storagePath = active.storagePath
  }

  return track
}

async function decodeVersion(data: DocumentData): Promise<TrackVersion | null> {
  if (typeof data.id !== "string" || typeof data.fileName !== "string") return null
  return {
    id: data.id,
    name: asString(data.name),
    fileName: data.fileName,
    fileSize: asNumber(data.fileSize),
    duration: asNumber(data.duration),
    addedDate: asDate(data.addedDate) ?? new Date(),
    waveform: typeof data.waveform === "string" ? await decodeWaveform(data.waveform) : undefined,
    storagePath: asString(data.storagePath),
    isPublic: data.isPublic !== false,
  }
}

export function decodeGradient(data: unknown): GradientTheme | null {
  if (!data || typeof data !== "object") return null
  const g = data as DocumentData
  if (!Array.isArray(g.colors)) return null
  return {
    colors: g.colors,
    startX: asNumber(g.startX),
    startY: asNumber(g.startY),
    endX: asNumber(g.endX),
    endY: asNumber(g.endY),
  }
}

// MARK: - Encoding (mirrors the iOS `FirestoreProjectCodec.encode`)

export async function encodeProject(project: Project): Promise<Record<string, unknown>> {
  const payload: Record<string, unknown> = {
    id: project.id,
    name: project.name,
    gradient: encodeGradient(project.gradient),
    tracks: await Promise.all(project.tracks.map(encodeTrack)),
    createdDate: Timestamp.fromDate(project.createdDate),
    updatedDate: Timestamp.fromDate(project.updatedDate),
  }
  if (project.ownerUsername) payload.ownerUsername = project.ownerUsername
  if (project.coverStoragePath) payload.coverStoragePath = project.coverStoragePath
  if (project.accentColorHex) payload.accentColorHex = project.accentColorHex
  if (project.coverGradientColors) payload.coverGradientColors = project.coverGradientColors
  return payload
}

export async function encodeTrack(track: Track): Promise<Record<string, unknown>> {
  const payload: Record<string, unknown> = {
    id: track.id,
    title: track.title,
    fileName: track.fileName,
    fileSize: track.fileSize,
    duration: track.duration,
    addedDate: Timestamp.fromDate(track.addedDate),
  }
  if (track.storagePath) payload.storagePath = track.storagePath
  if (track.notes) payload.notes = track.notes
  if (track.versions.length > 0) {
    payload.versions = await Promise.all(track.versions.map(encodeVersion))
    if (track.activeVersionID) payload.activeVersionID = track.activeVersionID
  }
  if (track.waveform && track.waveform.length > 0) {
    const encoded = await encodeWaveform(track.waveform)
    if (encoded) payload.waveform = encoded
  }
  return payload
}

async function encodeVersion(version: TrackVersion): Promise<Record<string, unknown>> {
  const payload: Record<string, unknown> = {
    id: version.id,
    fileName: version.fileName,
    fileSize: version.fileSize,
    duration: version.duration,
    addedDate: Timestamp.fromDate(version.addedDate),
    isPublic: version.isPublic,
  }
  if (version.name) payload.name = version.name
  if (version.storagePath) payload.storagePath = version.storagePath
  if (version.waveform && version.waveform.length > 0) {
    const encoded = await encodeWaveform(version.waveform)
    if (encoded) payload.waveform = encoded
  }
  return payload
}

export function encodeGradient(gradient: GradientTheme): Record<string, unknown> {
  return {
    colors: gradient.colors,
    startX: gradient.startX,
    startY: gradient.startY,
    endX: gradient.endX,
    endY: gradient.endY,
  }
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined
}

function asNumber(value: unknown): number {
  return typeof value === "number" ? value : 0
}

function asDate(value: unknown): Date | undefined {
  return value instanceof Timestamp ? value.toDate() : undefined
}
