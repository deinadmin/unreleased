import {
  doc,
  onSnapshot,
  runTransaction,
  serverTimestamp,
  setDoc,
  type DocumentData,
  type DocumentReference,
  type DocumentSnapshot,
  type Unsubscribe,
} from "firebase/firestore"
import { db } from "@/lib/firebase"
import {
  EQUALIZER_BANDS,
  clampGain,
  type CustomEqualizerPreset,
} from "@/player/equalizer"

export interface EqualizerSyncState {
  customPresets: CustomEqualizerPreset[]
}

type RemoteUpdate = (state: EqualizerSyncState) => void

function cloneState(state: EqualizerSyncState): EqualizerSyncState {
  return {
    customPresets: state.customPresets.map((preset) => ({
      ...preset,
      gains: [...preset.gains],
    })),
  }
}

function statesEqual(a: EqualizerSyncState, b: EqualizerSyncState | null): boolean {
  if (!b || a.customPresets.length !== b.customPresets.length) return false
  return a.customPresets.every((preset, index) => {
    const other = b.customPresets[index]
    return (
      preset.id === other.id &&
      preset.title === other.title &&
      preset.gains.length === other.gains.length &&
      preset.gains.every((gain, gainIndex) => gain === other.gains[gainIndex])
    )
  })
}

function decodeGains(value: unknown): number[] | null {
  if (
    !Array.isArray(value) ||
    value.length !== EQUALIZER_BANDS.length ||
    value.some((gain) => typeof gain !== "number" || !Number.isFinite(gain))
  ) {
    return null
  }
  return value.map(clampGain)
}

function decodeState(data: DocumentData | undefined): EqualizerSyncState | null {
  if (!data) return null

  const rawPresets = Array.isArray(data.customPresets) ? data.customPresets : []
  const customPresets = rawPresets.flatMap((value): CustomEqualizerPreset[] => {
    if (!value || typeof value !== "object") return []
    const preset = value as Record<string, unknown>
    const presetGains = decodeGains(preset.gains)
    const title = typeof preset.title === "string" ? preset.title.trim() : ""
    if (typeof preset.id !== "string" || !title || !presetGains) return []
    return [{ id: preset.id.toLowerCase(), title, gains: presetGains }]
  })

  return { customPresets }
}

function encodeState(state: EqualizerSyncState): DocumentData {
  return {
    schemaVersion: 1,
    customPresets: state.customPresets.map((preset) => ({
      id: preset.id.toLowerCase(),
      title: preset.title,
      gains: preset.gains,
    })),
    updatedAt: serverTimestamp(),
  }
}

/**
 * Real-time, last-explicit-change-wins sync for the account's custom presets.
 * The current curve and enabled state never enter this document.
 */
export class EqualizerSyncSession {
  private readonly reference: DocumentReference<DocumentData>
  private unsubscribe: Unsubscribe | null = null
  private writeTimer: ReturnType<typeof setTimeout> | null = null
  private latestState: EqualizerSyncState
  private receivedInitialSnapshot = false
  private changedBeforeInitialSnapshot = false
  private localRevision = 0
  private finishedRevision = 0
  private stopped = false

  constructor(
    userID: string,
    localState: EqualizerSyncState,
    private readonly onRemoteUpdate: RemoteUpdate,
  ) {
    this.reference = doc(db, "users", userID, "private", "equalizerPresets")
    this.latestState = cloneState(localState)
  }

  start() {
    this.unsubscribe = onSnapshot(
      this.reference,
      (snapshot) => this.receive(snapshot),
      (error) => console.error("equalizer sync listener failed", error),
    )
  }

  stop() {
    this.stopped = true
    this.unsubscribe?.()
    this.unsubscribe = null
    if (this.writeTimer) clearTimeout(this.writeTimer)
    this.writeTimer = null
  }

  stateDidChange(state: EqualizerSyncState) {
    this.latestState = cloneState(state)
    this.localRevision += 1

    if (!this.receivedInitialSnapshot) {
      this.changedBeforeInitialSnapshot = true
      return
    }
    this.scheduleUpload()
  }

  private get hasPendingLocalChange() {
    return this.localRevision > this.finishedRevision
  }

  private receive(snapshot: DocumentSnapshot<DocumentData>) {
    if (this.stopped) return
    const remoteState = decodeState(snapshot.data())

    if (!this.receivedInitialSnapshot) {
      this.receivedInitialSnapshot = true
      if (remoteState) {
        if (this.changedBeforeInitialSnapshot) {
          this.scheduleUpload()
        } else {
          this.acceptRemote(remoteState)
        }
      } else if (snapshot.exists()) {
        // Replace malformed cloud data with the validated local cache.
        this.scheduleUpload()
      } else {
        void this.createDocumentIfMissing()
      }
      return
    }

    if (!remoteState) return
    if (this.hasPendingLocalChange && !statesEqual(remoteState, this.latestState)) {
      return
    }
    this.acceptRemote(remoteState)
  }

  private acceptRemote(state: EqualizerSyncState) {
    this.latestState = cloneState(state)
    this.localRevision = 0
    this.finishedRevision = 0
    this.onRemoteUpdate(cloneState(state))
  }

  private scheduleUpload() {
    if (this.writeTimer) clearTimeout(this.writeTimer)
    this.writeTimer = setTimeout(() => {
      this.writeTimer = null
      void this.uploadLatestState()
    }, 0)
  }

  private async uploadLatestState() {
    if (this.stopped) return
    const state = cloneState(this.latestState)
    const revision = this.localRevision
    try {
      await setDoc(this.reference, encodeState(state))
      if (this.localRevision === revision) this.finishedRevision = revision
    } catch (error) {
      console.error("equalizer sync upload failed", error)
    }
  }

  private async createDocumentIfMissing() {
    try {
      await runTransaction(db, async (transaction) => {
        const snapshot = await transaction.get(this.reference)
        if (!snapshot.exists()) {
          transaction.set(this.reference, encodeState(this.latestState))
        }
      })
    } catch (error) {
      console.error("equalizer initial sync failed", error)
    }
  }
}
