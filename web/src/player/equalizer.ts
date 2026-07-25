/**
 * 1:1 port of the iOS equalizer (`EqualizerConfiguration.swift` plus the
 * equalizer half of `AudioPlayer.swift`).
 *
 * The iOS engine runs an `AVAudioUnitEQ` with seven parametric bands (1 octave
 * bandwidth) between the player node and the mixer. The web equivalent is a
 * chain of `BiquadFilterNode`s in "peaking" mode — the same filter topology —
 * fed by a `MediaElementAudioSourceNode` for the shared `<audio>` element.
 */

export interface EqualizerBand {
  id: number
  frequency: number
  label: string
  character: string
}

export const EQUALIZER_BANDS: EqualizerBand[] = [
  { id: 0, frequency: 60, label: "60", character: "Sub" },
  { id: 1, frequency: 150, label: "150", character: "Bass" },
  { id: 2, frequency: 400, label: "400", character: "Warmth" },
  { id: 3, frequency: 1_000, label: "1k", character: "Body" },
  { id: 4, frequency: 2_400, label: "2.4k", character: "Presence" },
  { id: 5, frequency: 6_000, label: "6k", character: "Clarity" },
  { id: 6, frequency: 14_000, label: "14k", character: "Air" },
]

export interface EqualizerPreset {
  id: string
  title: string
  detail: string
  gains: number[]
}

export const EQUALIZER_PRESETS: EqualizerPreset[] = [
  { id: "flat", title: "Flat", detail: "No frequency shaping", gains: [0, 0, 0, 0, 0, 0, 0] },
  {
    id: "bassBoost",
    title: "Bass Boost",
    detail: "Deeper lows with a clean top end",
    gains: [6, 4.5, 2, 0, -1, -1, 0],
  },
  { id: "vocal", title: "Vocal", detail: "Brings voices forward", gains: [-2, -1, 0, 2.5, 4, 2, 0] },
  { id: "warm", title: "Warm", detail: "Fuller lows and softer highs", gains: [3.5, 3, 2, 0.5, -1, -2, -2] },
  { id: "bright", title: "Bright", detail: "More clarity, detail, and air", gains: [-2, -1, 0, 1, 2.5, 4, 5] },
  {
    id: "acoustic",
    title: "Acoustic",
    detail: "Natural presence and definition",
    gains: [1.5, 2, 1, -0.5, 2, 2.5, 1.5],
  },
]

export interface CustomEqualizerPreset {
  id: string
  title: string
  gains: number[]
}

export const FLAT_GAINS = EQUALIZER_PRESETS[0].gains
/** Matches the iOS ±12 dB drag range and 0.5 dB stepping. */
export const MAX_GAIN = 12
export const GAIN_STEP = 0.5
/** iOS treats gains closer than this as equal (preset matching, reset state). */
const GAIN_EPSILON = 0.05

export function clampGain(gain: number): number {
  return Math.min(MAX_GAIN, Math.max(-MAX_GAIN, gain))
}

export function gainsMatch(a: number[], b: number[]): boolean {
  return a.length === b.length && a.every((value, index) => Math.abs(value - b[index]) < GAIN_EPSILON)
}

export function isFlat(gains: number[]): boolean {
  return gains.every((gain) => Math.abs(gain) < GAIN_EPSILON)
}

export function findPreset(gains: number[]): EqualizerPreset | null {
  return EQUALIZER_PRESETS.find((preset) => gainsMatch(preset.gains, gains)) ?? null
}

/** Custom presets only claim the curve when no built-in preset already matches. */
export function findCustomPreset(
  gains: number[],
  presets: CustomEqualizerPreset[],
): CustomEqualizerPreset | null {
  if (findPreset(gains)) return null
  return presets.find((preset) => gainsMatch(preset.gains, gains)) ?? null
}

/** `String(format: "%+.1f dB")`, with an unsigned zero like iOS. */
export function formatGain(gain: number): string {
  if (Math.abs(gain) < GAIN_EPSILON) return "0 dB"
  return `${gain > 0 ? "+" : "-"}${Math.abs(gain).toFixed(1)} dB`
}

/** iOS `equalizer.globalGain`: pull back up to 6 dB of headroom when boosting. */
export function makeupGainDecibels(gains: number[], enabled: boolean): number {
  if (!enabled) return 0
  const highestBoost = gains.length > 0 ? Math.max(...gains) : 0
  return -Math.min(Math.max(highestBoost * 0.55, 0), 6)
}

// MARK: - Local cache (mirrors the iOS UserDefaults representation)

const ENABLED_KEY = "audio.equalizer.enabled"
const GAINS_KEY = "audio.equalizer.gains"
const CUSTOM_PRESETS_KEY = "audio.equalizer.customPresets"
const PRESETS_OWNER_ID_KEY = "audio.equalizer.presetsOwnerID"

function read(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}

function write(key: string, value: string) {
  try {
    localStorage.setItem(key, value)
  } catch {
    // Ignore storage errors (quota, private browsing).
  }
}

export function loadEnabled(): boolean {
  return read(ENABLED_KEY) === "true"
}

export function loadGains(): number[] {
  try {
    const stored = JSON.parse(read(GAINS_KEY) ?? "null")
    if (
      Array.isArray(stored) &&
      stored.length === EQUALIZER_BANDS.length &&
      stored.every((value) => typeof value === "number" && Number.isFinite(value))
    ) {
      return stored.map(clampGain)
    }
  } catch {
    // Fall through to the flat curve.
  }
  return [...FLAT_GAINS]
}

export function loadCustomPresets(): CustomEqualizerPreset[] {
  try {
    const stored = JSON.parse(read(CUSTOM_PRESETS_KEY) ?? "null")
    if (!Array.isArray(stored)) return []
    return stored.flatMap((preset): CustomEqualizerPreset[] => {
      const title = typeof preset?.title === "string" ? preset.title.trim() : ""
      if (
        !preset ||
        typeof preset.id !== "string" ||
        !title ||
        !Array.isArray(preset.gains) ||
        preset.gains.length !== EQUALIZER_BANDS.length ||
        preset.gains.some((gain: unknown) => typeof gain !== "number" || !Number.isFinite(gain))
      ) {
        return []
      }
      return [{ id: preset.id, title, gains: preset.gains.map(clampGain) }]
    })
  } catch {
    return []
  }
}

export function persistEnabled(enabled: boolean) {
  write(ENABLED_KEY, String(enabled))
}

export function persistGains(gains: number[]) {
  write(GAINS_KEY, JSON.stringify(gains))
}

export function persistCustomPresets(presets: CustomEqualizerPreset[]) {
  write(CUSTOM_PRESETS_KEY, JSON.stringify(presets))
}

export function loadEqualizerPresetsOwnerID(): string | null {
  return read(PRESETS_OWNER_ID_KEY)
}

export function persistEqualizerPresetsOwnerID(userID: string) {
  write(PRESETS_OWNER_ID_KEY, userID)
}

// MARK: - Audio graph

/**
 * `AVAudioUnitEQ` bands are specified in octaves; Web Audio peaking filters use
 * Q. For a one-octave bandwidth (the iOS `band.bandwidth = 1`):
 * `Q = sqrt(2^N) / (2^N - 1)`.
 */
const BAND_Q = Math.SQRT2

/** An element can only ever have one MediaElementAudioSourceNode. */
const attached = new WeakSet<HTMLAudioElement>()

/**
 * Routing policy for the shared `<audio>` element.
 *
 * Web Audio only sees a cross-origin media element that was fetched with CORS —
 * anything else makes the source node emit silence — and Cloud Storage only
 * sends the matching headers when the bucket carries a CORS policy for this
 * origin. So the element is loaded anonymously only while the equalizer needs
 * it, the graph is attached only once such a load has actually succeeded, and a
 * rejected load turns the routing off for the session rather than taking
 * playback down with it.
 */
export const equalizerRouting = {
  /** The equalizer would like the element routed through Web Audio. */
  wanted: false,
  /** A CORS load already failed, so the bucket has no policy for this origin. */
  blocked: false,
  graph: null as EqualizerGraph | null,

  /** Applies the CORS mode for the next load. Must run before assigning `src`. */
  prepare(audio: HTMLAudioElement) {
    // Once attached, the element is permanently routed through the graph and
    // every later load has to stay CORS-clean to remain audible.
    const mode = this.graph || (this.wanted && !this.blocked) ? "anonymous" : null
    if (audio.crossOrigin !== mode) audio.crossOrigin = mode
  },

  /** Builds the graph once a CORS-clean resource is loaded. */
  attachIfReady(audio: HTMLAudioElement): EqualizerGraph | null {
    if (this.graph) return this.graph
    if (!this.wanted || this.blocked) return null
    if (audio.crossOrigin !== "anonymous" || audio.readyState === 0) return null
    this.graph = EqualizerGraph.attach(audio)
    return this.graph
  },

  /**
   * Handles a load that failed because the response carried no CORS headers.
   * Returns true when the caller should retry the same source, which now loads
   * without CORS (and therefore without the equalizer).
   */
  recoverFromLoadFailure(audio: HTMLAudioElement): boolean {
    if (this.graph || audio.crossOrigin !== "anonymous") return false
    this.blocked = true
    audio.crossOrigin = null
    console.warn(
      "Equalizer inactive: playback is served without CORS headers, so Web Audio can't read it. " +
        "Add a CORS policy for this origin to the Cloud Storage bucket to enable it.",
    )
    return true
  },
}

export class EqualizerGraph {
  private constructor(
    private readonly context: AudioContext,
    private readonly filters: BiquadFilterNode[],
    private readonly makeup: GainNode,
  ) {}

  /** Routes the element through the filter chain; returns null if unsupported. */
  static attach(audio: HTMLAudioElement): EqualizerGraph | null {
    const Constructor =
      window.AudioContext ??
      (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
    if (!Constructor || attached.has(audio)) return null

    try {
      const context = new Constructor()
      const source = context.createMediaElementSource(audio)
      const filters = EQUALIZER_BANDS.map((band) => {
        const filter = context.createBiquadFilter()
        filter.type = "peaking"
        filter.frequency.value = band.frequency
        filter.Q.value = BAND_Q
        filter.gain.value = 0
        return filter
      })
      const makeup = context.createGain()

      const chain: AudioNode[] = [source, ...filters, makeup, context.destination]
      chain.forEach((node, index) => {
        if (index < chain.length - 1) node.connect(chain[index + 1])
      })

      attached.add(audio)
      return new EqualizerGraph(context, filters, makeup)
    } catch (error) {
      console.error("equalizer unavailable", error)
      return null
    }
  }

  /** Mirrors `applyEqualizerSettings()` — disabled bands sit flat (0 dB). */
  apply(gains: number[], enabled: boolean) {
    const now = this.context.currentTime
    this.filters.forEach((filter, index) => {
      // Short ramps instead of jumps so dragging doesn't produce zipper noise.
      filter.gain.setTargetAtTime(enabled ? (gains[index] ?? 0) : 0, now, 0.015)
    })
    const makeup = 10 ** (makeupGainDecibels(gains, enabled) / 20)
    this.makeup.gain.setTargetAtTime(makeup, now, 0.015)
  }

  /** Autoplay policies start the context suspended; resume on user-driven play. */
  resume() {
    if (this.context.state === "suspended") void this.context.resume().catch(() => {})
  }
}
