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
import {
  EQUALIZER_BANDS,
  FLAT_GAINS,
  clampGain,
  equalizerRouting,
  findCustomPreset,
  findPreset,
  loadCustomPresets,
  loadEnabled,
  loadEqualizerPresetsOwnerID,
  loadGains,
  persistCustomPresets,
  persistEnabled,
  persistEqualizerPresetsOwnerID,
  persistGains,
  type CustomEqualizerPreset,
  type EqualizerPreset,
} from "@/player/equalizer"
import { EqualizerSyncSession } from "@/player/equalizer-sync"
import { useAuth } from "@/hooks/use-auth"
import { usePlayer } from "@/player/player-provider"

interface EqualizerContextValue {
  enabled: boolean
  /** Per-band gain in dB (−12…12), one entry per `EQUALIZER_BANDS` band. */
  gains: number[]
  customPresets: CustomEqualizerPreset[]
  /** Built-in preset matching the current curve, if any. */
  activePreset: EqualizerPreset | null
  /** Custom preset matching the current curve (never set when a built-in matches). */
  activeCustomPreset: CustomEqualizerPreset | null
  setEnabled: (enabled: boolean) => void
  setGain: (gain: number, index: number) => void
  applyPreset: (preset: EqualizerPreset) => void
  applyCustomPreset: (preset: CustomEqualizerPreset) => void
  saveCustomPreset: (title: string) => void
  renameCustomPreset: (id: string, title: string) => void
  deleteCustomPreset: (id: string) => void
  reset: () => void
}

const EqualizerContext = createContext<EqualizerContextValue | null>(null)

function newPresetID(): string {
  return crypto.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/**
 * Re-fetches the current source under the active CORS policy, holding the
 * playhead. If the bucket rejects the CORS request the routing gives up and the
 * plain load is restored, so the listener hears an uninterrupted track either
 * way.
 */
function reloadInPlace(audio: HTMLAudioElement) {
  const source = audio.currentSrc
  const resumeAt = audio.currentTime
  const wasPlaying = !audio.paused

  const finish = () => {
    audio.removeEventListener("loadedmetadata", onLoaded)
    audio.removeEventListener("error", onError)
  }
  const onLoaded = () => {
    finish()
    audio.currentTime = resumeAt
    if (wasPlaying) void audio.play().catch(() => {})
  }
  const onError = () => {
    finish()
    if (equalizerRouting.recoverFromLoadFailure(audio)) reloadInPlace(audio)
  }

  audio.addEventListener("loadedmetadata", onLoaded)
  audio.addEventListener("error", onError)
  equalizerRouting.prepare(audio)
  audio.src = source
  audio.load()
}

/**
 * Web port of the equalizer state on the iOS `AudioPlayer`: the curve is global,
 * persisted, and applied to every track the shared player element plays.
 */
export function EqualizerProvider({ children }: { children: ReactNode }) {
  const { audio } = usePlayer()
  const { user } = useAuth()
  const [enabled, setEnabledState] = useState(loadEnabled)
  const [gains, setGains] = useState(loadGains)
  const [customPresets, setCustomPresets] = useState(loadCustomPresets)
  const settingsRef = useRef({ gains, enabled, customPresets })
  const syncSessionRef = useRef<EqualizerSyncSession | null>(null)
  settingsRef.current = { gains, enabled, customPresets }
  const syncUserID = user && !user.isAnonymous ? user.uid : null

  useEffect(() => {
    syncSessionRef.current?.stop()
    syncSessionRef.current = null
    if (!syncUserID) return

    const previousOwnerID = loadEqualizerPresetsOwnerID()
    let initialPresets = settingsRef.current.customPresets

    // Migrate the old local preset cache to the first account that uses it,
    // while keeping the current device-local curve completely untouched.
    if (previousOwnerID && previousOwnerID !== syncUserID) {
      initialPresets = []
      settingsRef.current = { ...settingsRef.current, customPresets: [] }
      setCustomPresets([])
      persistCustomPresets([])
    }
    persistEqualizerPresetsOwnerID(syncUserID)

    const session = new EqualizerSyncSession(
      syncUserID,
      { customPresets: initialPresets },
      (state) => {
        settingsRef.current = { ...settingsRef.current, customPresets: state.customPresets }
        setCustomPresets(state.customPresets)
        persistCustomPresets(state.customPresets)
      },
    )
    syncSessionRef.current = session
    session.start()

    return () => {
      session.stop()
      if (syncSessionRef.current === session) syncSessionRef.current = null
    }
  }, [syncUserID])

  // The graph is built on first use: while the EQ has never been switched on,
  // playback stays on the plain element path.
  useEffect(() => {
    equalizerRouting.wanted = enabled
    equalizerRouting.attachIfReady(audio)?.apply(gains, enabled)
  }, [audio, enabled, gains])

  useEffect(() => {
    const sync = () => {
      const graph = equalizerRouting.attachIfReady(audio)
      graph?.apply(settingsRef.current.gains, settingsRef.current.enabled)
      return graph
    }
    // A track that finished loading with CORS is the first chance to route it.
    audio.addEventListener("loadedmetadata", sync)
    // Once routed through an AudioContext, playback is silent while that
    // context is suspended — resume it alongside every user-driven play.
    const onPlay = () => sync()?.resume()
    audio.addEventListener("play", onPlay)
    return () => {
      audio.removeEventListener("loadedmetadata", sync)
      audio.removeEventListener("play", onPlay)
    }
  }, [audio])

  // Switching the EQ on mid-track: the loaded resource was fetched without
  // CORS, so it has to be re-fetched before Web Audio may read it.
  useEffect(() => {
    if (!enabled || equalizerRouting.graph || equalizerRouting.blocked) return
    if (!audio.currentSrc || audio.crossOrigin === "anonymous") return
    reloadInPlace(audio)
  }, [audio, enabled])

  const setEnabled = useCallback((next: boolean) => {
    if (settingsRef.current.enabled === next) return
    settingsRef.current = { ...settingsRef.current, enabled: next }
    setEnabledState(next)
    persistEnabled(next)
  }, [])

  const commitGains = useCallback((next: number[]) => {
    settingsRef.current = { ...settingsRef.current, gains: next }
    setGains(next)
    persistGains(next)
  }, [])

  const commitCustomPresets = useCallback((next: CustomEqualizerPreset[]) => {
    settingsRef.current = { ...settingsRef.current, customPresets: next }
    setCustomPresets(next)
    persistCustomPresets(next)
    syncSessionRef.current?.stateDidChange({ customPresets: next })
  }, [])

  const setGain = useCallback(
    (gain: number, index: number) => {
      if (index < 0 || index >= EQUALIZER_BANDS.length) return
      const next = [...settingsRef.current.gains]
      next[index] = clampGain(gain)
      commitGains(next)
    },
    [commitGains],
  )

  // Applying a preset also switches the EQ on, like iOS.
  const applyPreset = useCallback(
    (preset: EqualizerPreset) => {
      commitGains([...preset.gains])
      setEnabled(true)
    },
    [commitGains, setEnabled],
  )

  const applyCustomPreset = useCallback(
    (preset: CustomEqualizerPreset) => {
      if (preset.gains.length !== EQUALIZER_BANDS.length) return
      commitGains([...preset.gains])
      setEnabled(true)
    },
    [commitGains, setEnabled],
  )

  const saveCustomPreset = useCallback(
    (title: string) => {
      const trimmed = title.trim()
      if (!trimmed) return
      const current = settingsRef.current
      commitCustomPresets([
        ...current.customPresets,
        { id: newPresetID(), title: trimmed, gains: [...current.gains] },
      ])
    },
    [commitCustomPresets],
  )

  const renameCustomPreset = useCallback(
    (id: string, title: string) => {
      const trimmed = title.trim()
      if (!trimmed) return
      commitCustomPresets(
        settingsRef.current.customPresets.map((preset) =>
          preset.id === id ? { ...preset, title: trimmed } : preset,
        ),
      )
    },
    [commitCustomPresets],
  )

  const deleteCustomPreset = useCallback(
    (id: string) => {
      commitCustomPresets(
        settingsRef.current.customPresets.filter((preset) => preset.id !== id),
      )
    },
    [commitCustomPresets],
  )

  const reset = useCallback(() => commitGains([...FLAT_GAINS]), [commitGains])

  const value = useMemo<EqualizerContextValue>(
    () => ({
      enabled,
      gains,
      customPresets,
      activePreset: findPreset(gains),
      activeCustomPreset: findCustomPreset(gains, customPresets),
      setEnabled,
      setGain,
      applyPreset,
      applyCustomPreset,
      saveCustomPreset,
      renameCustomPreset,
      deleteCustomPreset,
      reset,
    }),
    [
      enabled,
      gains,
      customPresets,
      setEnabled,
      setGain,
      applyPreset,
      applyCustomPreset,
      saveCustomPreset,
      renameCustomPreset,
      deleteCustomPreset,
      reset,
    ],
  )

  return <EqualizerContext.Provider value={value}>{children}</EqualizerContext.Provider>
}

export function useEqualizer(): EqualizerContextValue {
  const context = useContext(EqualizerContext)
  if (!context) throw new Error("useEqualizer must be used within EqualizerProvider")
  return context
}
