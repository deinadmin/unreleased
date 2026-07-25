import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { toast } from "sonner"
import { downloadURL } from "@/lib/storage-urls"
import { equalizerRouting } from "@/player/equalizer"
import type { Project, Track } from "@/lib/types"

interface PlayerContextValue {
  project: Project | null
  track: Track | null
  isPlaying: boolean
  /** Duration in seconds (falls back to track metadata until audio loads). */
  duration: number
  /** Low-frequency progress fraction (0…1) for coarse UI. */
  progress: number
  /** The underlying element — waveforms rAF-read currentTime for smooth motion. */
  audio: HTMLAudioElement
  play: (track: Track, project: Project) => void
  togglePlayPause: () => void
  seek: (fraction: number) => void
  next: () => void
  previous: () => void
  /** Stops playback and dismisses the player chrome entirely. */
  stop: () => void
  expanded: boolean
  setExpanded: (expanded: boolean) => void
}

const PlayerContext = createContext<PlayerContextValue | null>(null)

function showUploadPendingToast(trackTitle: string) {
  toast("Still uploading", {
    description: `“${trackTitle}” hasn’t finished uploading yet. It’ll be playable on this device once the upload completes.`,
  })
}

export function PlayerProvider({ children }: { children: ReactNode }) {
  const audioRef = useRef<HTMLAudioElement | null>(null)
  if (audioRef.current === null) {
    audioRef.current = new Audio()
    audioRef.current.preload = "auto"
  }
  const audio = audioRef.current

  const [project, setProject] = useState<Project | null>(null)
  const [track, setTrack] = useState<Track | null>(null)
  const [isPlaying, setIsPlaying] = useState(false)
  const [duration, setDuration] = useState(0)
  const [progress, setProgress] = useState(0)
  const [expanded, setExpanded] = useState(false)
  // Monotonic token so a stale async URL resolution can't hijack playback.
  const loadToken = useRef(0)
  const projectRef = useRef<Project | null>(null)
  const trackRef = useRef<Track | null>(null)

  const play = useCallback(
    (nextTrack: Track, nextProject: Project) => {
      if (!nextTrack.storagePath) {
        showUploadPendingToast(nextTrack.title)
        return
      }
      const token = ++loadToken.current
      // First appearance of the player: big screens default to the maximized
      // sidebar, small screens to the mini player.
      if (!trackRef.current) {
        setExpanded(window.matchMedia("(min-width: 1024px)").matches)
      }
      setTrack(nextTrack)
      setProject(nextProject)
      trackRef.current = nextTrack
      projectRef.current = nextProject
      setDuration(nextTrack.duration)
      setProgress(0)
      downloadURL(nextTrack.storagePath)
        .then((url) => {
          if (loadToken.current !== token) return
          // The equalizer decides whether this load has to be a CORS request.
          equalizerRouting.prepare(audio)
          audio.src = url
          audio.currentTime = 0
          return audio.play().catch((error) => {
            // A CORS load the storage bucket refuses is recoverable: retry the
            // same source plainly, leaving the equalizer switched out.
            if (loadToken.current !== token) return
            if (!equalizerRouting.recoverFromLoadFailure(audio)) throw error
            audio.src = url
            audio.currentTime = 0
            return audio.play()
          })
        })
        .catch((error) => {
          if (loadToken.current !== token) return
          if ((error as { name?: string })?.name === "AbortError") return
          console.error("playback failed", error)
          if ((error as { code?: string })?.code === "storage/object-not-found") {
            showUploadPendingToast(nextTrack.title)
            return
          }
          toast("Couldn't play this track. Check your connection and try again.")
        })
    },
    [audio],
  )

  const togglePlayPause = useCallback(() => {
    if (!audio.src) return
    if (audio.paused) void audio.play().catch(() => {})
    else audio.pause()
  }, [audio])

  const seek = useCallback(
    (fraction: number) => {
      const total = audio.duration
      if (!Number.isFinite(total) || total <= 0) return
      audio.currentTime = Math.min(1, Math.max(0, fraction)) * total
      setProgress(fraction)
    },
    [audio],
  )

  const step = useCallback(
    (offset: number) => {
      const currentProject = projectRef.current
      const currentTrack = trackRef.current
      if (!currentProject || !currentTrack) return
      const playable = currentProject.tracks.filter((t) => t.storagePath)
      const index = playable.findIndex((t) => t.id === currentTrack.id)
      if (index === -1) return
      const nextIndex = index + offset
      if (nextIndex < 0 || nextIndex >= playable.length) {
        if (offset > 0) {
          audio.pause()
          audio.currentTime = 0
        }
        return
      }
      play(playable[nextIndex], currentProject)
    },
    [audio, play],
  )

  const stop = useCallback(() => {
    loadToken.current++
    audio.pause()
    audio.removeAttribute("src")
    setTrack(null)
    setProject(null)
    trackRef.current = null
    projectRef.current = null
    setIsPlaying(false)
    setProgress(0)
    setDuration(0)
    setExpanded(false)
  }, [audio])

  const next = useCallback(() => step(1), [step])
  const previous = useCallback(() => {
    if (audio.currentTime > 3) {
      audio.currentTime = 0
      return
    }
    step(-1)
  }, [audio, step])

  useEffect(() => {
    const onPlay = () => setIsPlaying(true)
    const onPause = () => setIsPlaying(false)
    const onLoaded = () => setDuration(audio.duration || trackRef.current?.duration || 0)
    const onTime = () => {
      const total = audio.duration
      setProgress(Number.isFinite(total) && total > 0 ? audio.currentTime / total : 0)
    }
    const onEnded = () => step(1)
    audio.addEventListener("play", onPlay)
    audio.addEventListener("pause", onPause)
    audio.addEventListener("loadedmetadata", onLoaded)
    audio.addEventListener("timeupdate", onTime)
    audio.addEventListener("ended", onEnded)
    return () => {
      audio.removeEventListener("play", onPlay)
      audio.removeEventListener("pause", onPause)
      audio.removeEventListener("loadedmetadata", onLoaded)
      audio.removeEventListener("timeupdate", onTime)
      audio.removeEventListener("ended", onEnded)
    }
  }, [audio, step])

  // Media Session integration for hardware keys / OS now-playing UI.
  useEffect(() => {
    if (!("mediaSession" in navigator) || !track || !project) return
    navigator.mediaSession.metadata = new MediaMetadata({
      title: track.title,
      artist: project.ownerUsername ?? "unreleased",
      album: project.name,
      artwork: [{ src: "/app-icon.png", sizes: "1024x1024", type: "image/png" }],
    })
    navigator.mediaSession.setActionHandler("play", () => void audio.play().catch(() => {}))
    navigator.mediaSession.setActionHandler("pause", () => audio.pause())
    navigator.mediaSession.setActionHandler("previoustrack", previous)
    navigator.mediaSession.setActionHandler("nexttrack", next)
  }, [audio, track, project, next, previous])

  const value = useMemo<PlayerContextValue>(
    () => ({
      project,
      track,
      isPlaying,
      duration,
      progress,
      audio,
      play,
      togglePlayPause,
      seek,
      next,
      previous,
      stop,
      expanded,
      setExpanded,
    }),
    [project, track, isPlaying, duration, progress, audio, play, togglePlayPause, seek, next, previous, stop, expanded],
  )

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>
}

export function usePlayer(): PlayerContextValue {
  const context = useContext(PlayerContext)
  if (!context) throw new Error("usePlayer must be used within PlayerProvider")
  return context
}
