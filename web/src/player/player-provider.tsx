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
import { toast } from "@/lib/toast"
import { downloadURL } from "@/lib/storage-urls"
import { preparePlayedTrackCache } from "@/lib/track-cache"
import { equalizerRouting } from "@/player/equalizer"
import type { Project, Track } from "@/lib/types"

interface PlayerContextValue {
  project: Project | null
  track: Track | null
  isPlaying: boolean
  /**
   * True from the moment a track is asked to play until its audio actually
   * starts. Version swaps are excluded — they deliberately hold the previous
   * transport state so the change reads as seamless.
   */
  isLoading: boolean
  /** Duration in seconds (falls back to track metadata until audio loads). */
  duration: number
  /** Low-frequency progress fraction (0…1) for coarse UI. */
  progress: number
  /** The underlying element — waveforms rAF-read currentTime for smooth motion. */
  audio: HTMLAudioElement
  /**
   * Playback fraction (0…1) for every rAF-driven surface. Prefer this over
   * reading the element: it holds the resume position steady while a version
   * swap loads, instead of dipping to zero with the empty media element.
   */
  getProgress: () => number
  play: (track: Track, project: Project) => void
  /**
   * Swaps the audio of the track already loaded for a different version,
   * resuming at `startAt` instead of restarting (iOS `AudioPlayer.switchToVersion`).
   */
  switchToVersion: (track: Track, project: Project, startAt: number, shouldPlay: boolean) => void
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
  const [isLoading, setIsLoading] = useState(false)
  const [duration, setDuration] = useState(0)
  const [progress, setProgress] = useState(0)
  const [expanded, setExpanded] = useState(false)
  // Monotonic token so a stale async URL resolution can't hijack playback.
  const loadToken = useRef(0)
  const projectRef = useRef<Project | null>(null)
  const trackRef = useRef<Track | null>(null)
  // Set while a version swap is loading: the media element reports no time and
  // counts as paused until the new source is ready, so the UI reads these.
  const heldProgress = useRef<number | null>(null)
  const heldPlaying = useRef<boolean | null>(null)

  const getProgress = useCallback(() => {
    if (heldProgress.current !== null) return heldProgress.current
    const total = audio.duration
    return Number.isFinite(total) && total > 0 ? audio.currentTime / total : 0
  }, [audio])

  const play = useCallback(
    (nextTrack: Track, nextProject: Project) => {
      const storagePath = nextTrack.storagePath
      if (!storagePath) {
        showUploadPendingToast(nextTrack.title)
        return
      }
      const token = ++loadToken.current
      heldProgress.current = null
      heldPlaying.current = null
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
      setIsLoading(true)
      downloadURL(storagePath)
        .then((url) => {
          if (loadToken.current !== token) return
          preparePlayedTrackCache(storagePath, nextTrack.fileSize)
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
        .finally(() => {
          // A newer load owns the transport now and manages its own spinner.
          if (loadToken.current === token) setIsLoading(false)
        })
    },
    [audio],
  )

  const switchToVersion = useCallback(
    (nextTrack: Track, nextProject: Project, startAt: number, shouldPlay: boolean) => {
      const storagePath = nextTrack.storagePath
      if (!storagePath) {
        showUploadPendingToast(nextTrack.title)
        return
      }
      const token = ++loadToken.current
      setTrack(nextTrack)
      setProject(nextProject)
      trackRef.current = nextTrack
      projectRef.current = nextProject
      setDuration(nextTrack.duration)
      // The swap is masked rather than announced, so no spinner here — and any
      // spinner left over from a load this one supersedes has to go.
      setIsLoading(false)

      // Pin the playhead to where the new version will resume, so swapping the
      // source never flashes the progress back to the start.
      const resumeAt = Math.min(Math.max(startAt, 0), nextTrack.duration || startAt)
      const held = nextTrack.duration > 0 ? resumeAt / nextTrack.duration : 0
      heldProgress.current = held
      setProgress(held)
      // Loading a new source pauses the element; keep the transport showing
      // "playing" so the button doesn't blink mid-swap.
      heldPlaying.current = shouldPlay ? true : null
      const release = () => {
        if (loadToken.current !== token) return
        heldProgress.current = null
        if (heldPlaying.current === null) return
        heldPlaying.current = null
        setIsPlaying(!audio.paused)
      }

      downloadURL(storagePath)
        .then((url) => {
          if (loadToken.current !== token) return
          preparePlayedTrackCache(storagePath, nextTrack.fileSize)

          const load = (canRetryWithoutCORS: boolean) => {
            // The equalizer decides whether this load has to be a CORS request.
            equalizerRouting.prepare(audio)
            const onReady = () => {
              audio.removeEventListener("error", onError)
              if (loadToken.current !== token) return
              audio.currentTime = Math.min(resumeAt, audio.duration || resumeAt)
              heldProgress.current = null
              if (!shouldPlay) {
                release()
                return
              }
              // Hold the transport until playback has actually resumed.
              void audio.play().catch(() => {}).finally(release)
            }
            const onError = () => {
              audio.removeEventListener("loadedmetadata", onReady)
              if (loadToken.current !== token) return
              // A CORS load the storage bucket refuses is recoverable: retry the
              // same source plainly, leaving the equalizer switched out.
              if (canRetryWithoutCORS && equalizerRouting.recoverFromLoadFailure(audio)) {
                load(false)
                return
              }
              release()
              toast("Couldn't play this version. Check your connection and try again.")
            }
            audio.addEventListener("loadedmetadata", onReady, { once: true })
            audio.addEventListener("error", onError, { once: true })
            audio.src = url
          }
          load(true)
        })
        .catch((error) => {
          if (loadToken.current !== token) return
          release()
          console.error("version playback failed", error)
          if ((error as { code?: string })?.code === "storage/object-not-found") {
            showUploadPendingToast(nextTrack.title)
            return
          }
          toast("Couldn't play this version. Check your connection and try again.")
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
    heldProgress.current = null
    heldPlaying.current = null
    audio.pause()
    audio.removeAttribute("src")
    setTrack(null)
    setProject(null)
    trackRef.current = null
    projectRef.current = null
    setIsPlaying(false)
    setIsLoading(false)
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
    // `play` fires the moment playback is *requested*, so the transport flips to
    // its playing state right away while the spinner keeps running. `playing`
    // is the one that means audio is actually coming out.
    const onPlay = () => setIsPlaying(true)
    const onPlaying = () => setIsLoading(false)
    const onPause = () => {
      // Swapping a version's source pauses the element on the way through.
      if (heldPlaying.current) return
      setIsPlaying(false)
    }
    const onLoaded = () => setDuration(audio.duration || trackRef.current?.duration || 0)
    const onTime = () => {
      // The pinned resume position wins until the swapped-in source is ready.
      if (heldProgress.current !== null) return
      const total = audio.duration
      setProgress(Number.isFinite(total) && total > 0 ? audio.currentTime / total : 0)
    }
    const onEnded = () => step(1)
    audio.addEventListener("play", onPlay)
    audio.addEventListener("playing", onPlaying)
    audio.addEventListener("pause", onPause)
    audio.addEventListener("loadedmetadata", onLoaded)
    audio.addEventListener("timeupdate", onTime)
    audio.addEventListener("ended", onEnded)
    return () => {
      audio.removeEventListener("play", onPlay)
      audio.removeEventListener("playing", onPlaying)
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
      isLoading,
      duration,
      progress,
      audio,
      getProgress,
      play,
      switchToVersion,
      togglePlayPause,
      seek,
      next,
      previous,
      stop,
      expanded,
      setExpanded,
    }),
    [project, track, isPlaying, isLoading, duration, progress, audio, getProgress, play, switchToVersion, togglePlayPause, seek, next, previous, stop, expanded],
  )

  return <PlayerContext.Provider value={value}>{children}</PlayerContext.Provider>
}

export function usePlayer(): PlayerContextValue {
  const context = useContext(PlayerContext)
  if (!context) throw new Error("usePlayer must be used within PlayerProvider")
  return context
}
