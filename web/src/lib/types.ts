export interface GradientTheme {
  colors: string[]
  startX: number
  startY: number
  endX: number
  endY: number
}

export interface TrackVersion {
  id: string
  name?: string
  fileName: string
  fileSize: number
  duration: number
  addedDate: Date
  waveform?: number[]
  storagePath?: string
  isPublic: boolean
}

export interface Track {
  id: string
  title: string
  fileName: string
  fileSize: number
  duration: number
  addedDate: Date
  waveform?: number[]
  storagePath?: string
  notes: string
  versions: TrackVersion[]
  activeVersionID?: string
}

export interface Project {
  id: string
  name: string
  gradient: GradientTheme
  coverStoragePath?: string
  accentColorHex?: string
  coverGradientColors?: string[]
  tracks: Track[]
  createdDate: Date
  updatedDate: Date
  ownerUsername?: string
  /** Non-nil when this project is shared from another user. Nil for own projects. */
  ownerID?: string
}

/** Publicly-readable invite preview (`users/{ownerID}/projectPreviews/{projectID}`). */
export interface ProjectPreview {
  projectID: string
  ownerUID: string
  ownerUsername: string
  name: string
  gradient: GradientTheme
  coverStoragePath?: string
  accentColorHex?: string
  linkEnabled: boolean
}

export interface InviteeInfo {
  id: string
  username: string
  acceptedAt: Date
}

export interface PendingInviteInfo {
  id: string
  username: string
  invitedAt: Date
  notificationID?: string
}

export interface UserSearchResult {
  id: string
  username: string
  avatarURL?: string
}

export interface AppNotification {
  id: string
  kind: "projectInvite" | "unknown"
  fromUID: string
  fromUsername: string
  projectID: string
  projectName: string
  projectGradient?: GradientTheme
  coverStoragePath?: string
  createdAt: Date
  read: boolean
}

const FALLBACK_ACCENT = "#667EEA"

/** The iOS `GradientTheme.presets`, used when creating projects on the web. */
export const GRADIENT_PRESETS: GradientTheme[] = [
  { colors: ["#FF6FD8", "#C46FFF"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#7EB8F0", "#8EC5FC"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#FF9A9E", "#FAD0C4"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#96FBC4", "#F9F586"], startX: 0.5, startY: 0, endX: 0.5, endY: 1 },
  { colors: ["#667EEA", "#764BA2"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#4FACFE", "#00F2FE"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#FFD200", "#F7971E"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#F953C6", "#B91D73"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#A18CD1", "#FBC2EB"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#11998E", "#38EF7D"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#2980B9", "#8E44AD"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#FFECD2", "#FCB69F"], startX: 0, startY: 1, endX: 1, endY: 0 },
  { colors: ["#D4FC79", "#96E6A1"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#E0C3FC", "#8EC5FC"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#F77062", "#FE5196"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#43E97B", "#38F9D7"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#FA709A", "#FEE140"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#30CFD0", "#330867"], startX: 0, startY: 0, endX: 1, endY: 1 },
  { colors: ["#89F7FE", "#66A6FF"], startX: 0, startY: 0, endX: 1, endY: 1 },
]

export function randomGradient(): GradientTheme {
  return GRADIENT_PRESETS[Math.floor(Math.random() * GRADIENT_PRESETS.length)]
}

/** CSS linear-gradient matching the SwiftUI GradientTheme rendering. */
export function gradientCSS(gradient: GradientTheme): string {
  const { colors, startX, startY, endX, endY } = gradient
  if (colors.length === 0) return FALLBACK_ACCENT
  if (colors.length === 1) return colors[0]
  const angle = (Math.atan2(endX - startX, -(endY - startY)) * 180) / Math.PI
  return `linear-gradient(${angle.toFixed(1)}deg, ${colors.join(", ")})`
}

/** Accent color for a project: stored hex, or the midpoint of its gradient. */
export function projectAccent(project: Project): string {
  if (project.accentColorHex) return project.accentColorHex
  const colors = project.gradient.colors
  if (colors.length === 0) return FALLBACK_ACCENT
  if (colors.length === 1) return colors[0]
  const a = hexToRgb(colors[0])
  const b = hexToRgb(colors[colors.length - 1])
  return rgbToHex((a.r + b.r) / 2, (a.g + b.g) / 2, (a.b + b.b) / 2)
}

/** Gradient used for the vinyl label (cover-extracted colors when present). */
export function vinylGradientCSS(project: Project): string {
  if (project.coverGradientColors && project.coverGradientColors.length >= 2) {
    return `linear-gradient(135deg, ${project.coverGradientColors.join(", ")})`
  }
  return gradientCSS(project.gradient)
}

export function trackCountText(project: Project): string {
  const n = project.tracks.length
  return n === 1 ? "1 track" : `${n} tracks`
}

/**
 * Mirrors the iOS `selectPublicVersionsForSharedPlayback`: for shared listeners,
 * versioned tracks surface a public version's audio. Tracks whose versions are
 * all private are excluded entirely (their audio is not readable).
 */
export function sharedPlayableProject(project: Project): Project {
  const tracks = project.tracks.flatMap((track) => {
    if (track.versions.length === 0) return [track]
    const active = track.versions.find((v) => v.id === track.activeVersionID)
    const version = active?.isPublic ? active : track.versions.find((v) => v.isPublic)
    if (!version) return []
    return [
      {
        ...track,
        activeVersionID: version.id,
        fileName: version.fileName,
        fileSize: version.fileSize,
        duration: version.duration,
        waveform: version.waveform,
        storagePath: version.storagePath,
        versions: track.versions.filter((v) => v.isPublic),
      },
    ]
  })
  return { ...project, tracks }
}

function hexToRgb(hex: string): { r: number; g: number; b: number } {
  const cleaned = hex.replace(/[^0-9a-fA-F]/g, "")
  const int = parseInt(cleaned.length === 3 ? cleaned.split("").map((c) => c + c).join("") : cleaned, 16)
  return { r: (int >> 16) & 0xff, g: (int >> 8) & 0xff, b: int & 0xff }
}

function rgbToHex(r: number, g: number, b: number): string {
  const c = (v: number) => Math.round(v).toString(16).padStart(2, "0")
  return `#${c(r)}${c(g)}${c(b)}`
}
