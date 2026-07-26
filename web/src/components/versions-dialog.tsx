import { Eye, EyeOff, GripVertical, MoreHorizontal, Pause, Pencil, Play, Plus, Trash2 } from "lucide-react"
import { useCallback, useEffect, useRef, useState } from "react"
import { toast } from "@/lib/toast"
import { useContextMenu, type ContextMenuItem } from "@/components/context-menu"
import { ScrollingWaveform } from "@/components/scrolling-waveform"
import { VersionBadge } from "@/components/version-badge"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import { useProject } from "@/hooks/use-projects"
import { useSetActiveVersion } from "@/hooks/use-versions"
import { formatDuration, formatFileSize } from "@/lib/format"
import { downloadURL } from "@/lib/storage-urls"
import { projectAccent, type Project, type Track, type TrackVersion } from "@/lib/types"
import { cn } from "@/lib/utils"
import { deleteVersion, renameVersion, reorderVersions, setVersionPublic } from "@/lib/version-edits"
import {
  movedVersions,
  resolvedActiveVersionID,
  versionDisplayName,
  versionNumber,
  visibleVersions,
  withSelectedVersion,
} from "@/lib/versions"
import { usePlayer } from "@/player/player-provider"
import { AUDIO_ACCEPT } from "@/uploads/dropzone"
import { useUploads } from "@/uploads/uploads-provider"

// Neutral bar colors so the scrubber reads on both the light and dark popover.
const BAR_COLOR = "rgba(125,125,133,0.45)"
const PLAYED_COLOR = "rgba(125,125,133,0.95)"

/**
 * The version history of a track, mirroring the iOS `VersionsView`: pick the
 * active version, audition each one on its own scrubbable waveform, and (as the
 * owner) add, rename, hide, reorder or delete versions.
 */
export function VersionsDialog({
  project,
  track,
  open,
  onOpenChange,
}: {
  project: Project
  track: Track
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { user } = useAuth()
  const player = usePlayer()
  const contextMenu = useContextMenu()
  const setActiveVersion = useSetActiveVersion()
  const { importVersions, isImporting } = useUploads()
  const fileInput = useRef<HTMLInputElement>(null)

  // Prefer live store data over the snapshot the row was rendered with.
  const liveProject = useProject(project.id) ?? project
  const liveTrack = liveProject.tracks.find((t) => t.id === track.id) ?? track
  const isOwner = !liveProject.ownerID && Boolean(user)
  const accent = projectAccent(liveProject)

  const versions = visibleVersions(liveTrack, Boolean(liveProject.ownerID))
  const activeVersionID = resolvedActiveVersionID(liveTrack)
  const publicCount = versions.filter((version) => version.isPublic).length

  const [previewAudio, setPreviewAudio] = useState<HTMLAudioElement | null>(null)
  const [previewID, setPreviewID] = useState<string | null>(null)
  const [previewPlaying, setPreviewPlaying] = useState(false)
  const [loadingID, setLoadingID] = useState<string | null>(null)
  const [renameTarget, setRenameTarget] = useState<TrackVersion | null>(null)
  const [renameText, setRenameText] = useState("")
  const [deleteTarget, setDeleteTarget] = useState<TrackVersion | null>(null)
  // Non-null only while a card is being dragged; holds the live preview order.
  const [dragOrder, setDragOrder] = useState<string[] | null>(null)
  const [draggingID, setDraggingID] = useState<string | null>(null)

  // Mirrored imperatively so the async preview pipeline can bail out on a
  // stale load without waiting for a re-render.
  const previewIDRef = useRef<string | null>(null)
  const loadingIDRef = useRef<string | null>(null)
  const setPreview = (id: string | null) => {
    previewIDRef.current = id
    setPreviewID(id)
  }
  const setLoading = (id: string | null) => {
    loadingIDRef.current = id
    setLoadingID(id)
  }
  /** Whether the main player was playing this track when the dialog opened. */
  const wasPlayingOnEntry = useRef(false)

  const isCurrentTrack =
    player.track?.id === liveTrack.id && player.project?.id === liveProject.id

  useEffect(() => {
    if (!open) return
    setPreviewAudio((existing) => existing ?? new Audio())
  }, [open])

  // Capture the playback state to restore once the dialog closes.
  const playerRef = useRef(player)
  playerRef.current = player
  const isCurrentTrackRef = useRef(isCurrentTrack)
  isCurrentTrackRef.current = isCurrentTrack
  useEffect(() => {
    if (!open) return
    wasPlayingOnEntry.current = isCurrentTrackRef.current && playerRef.current.isPlaying
  }, [open])

  useEffect(() => {
    if (!previewAudio) return
    const onPlay = () => setPreviewPlaying(true)
    const onPause = () => setPreviewPlaying(false)
    previewAudio.addEventListener("play", onPlay)
    previewAudio.addEventListener("pause", onPause)
    previewAudio.addEventListener("ended", onPause)
    return () => {
      previewAudio.removeEventListener("play", onPlay)
      previewAudio.removeEventListener("pause", onPause)
      previewAudio.removeEventListener("ended", onPause)
    }
  }, [previewAudio])

  // Never leave a preview running once the dialog is gone.
  useEffect(() => () => previewAudio?.pause(), [previewAudio])

  const stopPreview = () => {
    previewAudio?.pause()
    setPreview(null)
    setLoading(null)
  }

  /** Loads and plays a version's audio, optionally starting at a fraction of it. */
  const loadPreview = async (version: TrackVersion, atFraction?: number) => {
    if (!previewAudio) return
    if (!version.storagePath) {
      toast("This version's audio isn't available yet.")
      return
    }
    // The main player steps aside while auditioning, like the iOS sheet.
    if (isCurrentTrack && player.isPlaying) player.togglePlayPause()

    setLoading(version.id)
    try {
      const url = await downloadURL(version.storagePath)
      if (loadingIDRef.current !== version.id) return
      previewAudio.pause()
      previewAudio.src = url
      setPreview(version.id)
      if (atFraction !== undefined) {
        previewAudio.addEventListener(
          "loadedmetadata",
          () => {
            if (previewIDRef.current !== version.id) return
            previewAudio.currentTime = atFraction * (previewAudio.duration || version.duration)
          },
          { once: true },
        )
      }
      await previewAudio.play()
    } catch (error) {
      console.error("version preview failed", error)
      toast("Couldn't play this version. Check your connection and try again.")
    } finally {
      if (loadingIDRef.current === version.id) setLoading(null)
    }
  }

  const togglePreview = (version: TrackVersion) => {
    if (previewID !== version.id || !previewAudio) {
      void loadPreview(version)
      return
    }
    if (previewAudio.paused) void previewAudio.play().catch(() => {})
    else previewAudio.pause()
  }

  const seekPreview = (version: TrackVersion, fraction: number) => {
    const clamped = Math.min(1, Math.max(0, fraction))
    if (previewID === version.id && previewAudio?.duration) {
      previewAudio.currentTime = clamped * previewAudio.duration
      return
    }
    void loadPreview(version, clamped)
  }

  /** Makes a version active and hands the running playback over to it. */
  const select = (version: TrackVersion) => {
    if (activeVersionID === version.id) return
    const resumeTime = player.audio.currentTime
    const shouldResume = player.isPlaying || (previewID !== null && wasPlayingOnEntry.current)

    stopPreview()
    setActiveVersion(liveProject, liveTrack.id, version.id)
    if (!isCurrentTrack) return

    // Switch immediately from the locally-updated track rather than waiting for
    // the write to come back through the projects listener.
    const updated = withSelectedVersion(liveTrack, version.id)
    player.switchToVersion(
      updated,
      liveProject,
      Math.min(resumeTime, updated.duration),
      shouldResume,
    )
  }

  /** Mirrors the iOS `finishPreviewSession`: put the main player back as it was. */
  const handleOpenChange = (next: boolean) => {
    if (next) return
    const wasPreviewing = previewID !== null
    stopPreview()
    onOpenChange(false)
    // Only a preview can have paused the main player; selecting a version
    // already resumed it when it should keep playing.
    if (isCurrentTrack && wasPreviewing && wasPlayingOnEntry.current && !player.isPlaying) {
      player.togglePlayPause()
    }
  }

  const addVersions = (files: File[]) => {
    if (files.length === 0) return
    stopPreview()
    void importVersions(files, liveProject.id, liveTrack.id)
  }

  const commitRename = async () => {
    if (!user || !renameTarget) return
    try {
      await renameVersion(user.uid, liveProject, liveTrack.id, renameTarget.id, renameText)
      setRenameTarget(null)
    } catch (error) {
      console.error("renaming version failed", error)
      toast("Couldn't rename this version. Please try again.")
    }
  }

  const toggleVisibility = async (version: TrackVersion) => {
    if (!user) return
    try {
      await setVersionPublic(user.uid, liveProject, liveTrack.id, version.id, !version.isPublic)
    } catch (error) {
      console.error("changing version visibility failed", error)
      toast("Couldn't change this version's visibility. Please try again.")
    }
  }

  const confirmDelete = async () => {
    if (!user || !deleteTarget) return
    if (previewID === deleteTarget.id) stopPreview()
    try {
      await deleteVersion(user.uid, liveProject, liveTrack.id, deleteTarget.id)
      setDeleteTarget(null)
    } catch (error) {
      console.error("deleting version failed", error)
      toast("Couldn't delete this version. Please try again.")
    }
  }

  const canReorder = isOwner && versions.length > 1
  const orderedVersions = dragOrder
    ? dragOrder.flatMap((id) => versions.filter((version) => version.id === id))
    : versions

  const dragOver = (targetID: string) => {
    if (!draggingID || draggingID === targetID) return
    const ids = orderedVersions.map((version) => version.id)
    const sourceIndex = ids.indexOf(draggingID)
    const targetIndex = ids.indexOf(targetID)
    if (sourceIndex === -1 || targetIndex === -1) return
    // The iOS drop delegate inserts past the target when dragging downward.
    const destination = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
    const next = movedVersions(orderedVersions, sourceIndex, destination).map((v) => v.id)
    if (next.every((id, index) => id === ids[index])) return
    setDragOrder(next)
  }

  const commitReorder = () => {
    const order = dragOrder
    setDraggingID(null)
    setDragOrder(null)
    if (!user || !order) return
    reorderVersions(user.uid, liveProject, liveTrack.id, order).catch((error) => {
      console.error("reordering versions failed", error)
      toast("Couldn't reorder the versions. Please try again.")
    })
  }

  const menuItems = (version: TrackVersion): ContextMenuItem[] => {
    if (!isOwner) return []
    const items: ContextMenuItem[] = [
      {
        label: "Rename version",
        icon: <Pencil />,
        onSelect: () => {
          setRenameText(versionDisplayName(liveTrack, version))
          setRenameTarget(version)
        },
      },
      {
        label: version.isPublic ? "Hide version" : "Show version",
        icon: version.isPublic ? <EyeOff /> : <Eye />,
        // A track always keeps one version its listeners can play.
        disabled: version.isPublic && publicCount <= 1,
        onSelect: () => void toggleVisibility(version),
      },
    ]
    if (versions.length > 1) {
      items.push({
        label: "Delete version",
        icon: <Trash2 />,
        destructive: true,
        onSelect: () => setDeleteTarget(version),
      })
    }
    return items
  }

  return (
    <>
      <Dialog open={open} onOpenChange={handleOpenChange}>
        <DialogContent
          // The app's context menu renders outside the dialog, so reaching for
          // it must not be treated as dismissing the dialog.
          onInteractOutside={(event) => {
            if ((event.target as HTMLElement | null)?.closest("[role='menu']")) {
              event.preventDefault()
            }
          }}
          className="max-h-[min(42rem,calc(100dvh-4rem))] grid-rows-[auto_minmax(0,1fr)] gap-0 overflow-hidden rounded-3xl p-0 sm:max-w-lg"
        >
          <DialogHeader className="gap-1 px-6 pt-6 pb-4">
            <DialogTitle className="text-[22px] font-bold">Versions</DialogTitle>
            <p className="truncate text-[13px] text-muted-foreground">{liveTrack.title}</p>
          </DialogHeader>

          <div className="flex min-h-0 flex-col gap-3 overflow-y-auto px-6 pt-1 pb-6">
            {isOwner && (
              <>
                <button
                  type="button"
                  disabled={isImporting}
                  onClick={() => fileInput.current?.click()}
                  className="flex h-12 w-full items-center justify-center gap-2 rounded-2xl bg-secondary text-[15px] font-medium transition hover:bg-secondary/70 active:scale-[0.99] disabled:opacity-50"
                >
                  {isImporting ? (
                    <span className="size-4 animate-spin rounded-full border-2 border-current border-t-transparent" />
                  ) : (
                    <Plus className="size-4" strokeWidth={2.5} />
                  )}
                  {isImporting ? "Adding version…" : "Add new version"}
                </button>
                <input
                  ref={fileInput}
                  type="file"
                  accept={AUDIO_ACCEPT}
                  multiple
                  className="hidden"
                  onChange={(event) => {
                    const files = Array.from(event.target.files ?? [])
                    event.target.value = ""
                    addVersions(files)
                  }}
                />
              </>
            )}

            {orderedVersions.map((version) => (
              <VersionCard
                key={version.id}
                version={version}
                accent={accent}
                name={versionDisplayName(liveTrack, version)}
                number={versionNumber(liveTrack, version.id) ?? 1}
                isSelected={activeVersionID === version.id}
                isPreviewing={previewID === version.id}
                isPreviewPlaying={previewID === version.id && previewPlaying}
                isLoading={loadingID === version.id}
                previewAudio={previewAudio}
                showsVisibility={isOwner}
                canReorder={canReorder}
                isDragging={draggingID === version.id}
                menuItems={menuItems}
                contextMenu={contextMenu}
                onSelect={() => select(version)}
                onTogglePreview={() => togglePreview(version)}
                onSeek={(fraction) => seekPreview(version, fraction)}
                onDragStart={() => setDraggingID(version.id)}
                onDragOver={() => dragOver(version.id)}
                onDragEnd={commitReorder}
              />
            ))}

            {canReorder && (
              <p className="px-1 text-[12px] text-muted-foreground">
                Drag a version by its handle to reorder. The top item always has the highest
                version number.
              </p>
            )}
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={renameTarget !== null} onOpenChange={(next) => !next && setRenameTarget(null)}>
        <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
          <form
            onSubmit={(event) => {
              event.preventDefault()
              void commitRename()
            }}
          >
            <DialogHeader className="min-w-0 pb-1">
              <DialogTitle>Rename version</DialogTitle>
            </DialogHeader>
            <input
              autoFocus
              value={renameText}
              onChange={(event) => setRenameText(event.target.value)}
              placeholder="Version name"
              aria-label="Version name"
              maxLength={120}
              className="mt-4 h-11 w-full rounded-xl bg-secondary px-3.5 text-[15px] outline-none ring-brand/60 transition placeholder:text-muted-foreground/60 focus:ring-2"
            />
            <div className="flex justify-end gap-2 pt-5">
              <Button type="button" variant="ghost" size="lg" onClick={() => setRenameTarget(null)}>
                Cancel
              </Button>
              <Button type="submit" size="lg">
                Rename
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      <Dialog open={deleteTarget !== null} onOpenChange={(next) => !next && setDeleteTarget(null)}>
        <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
          <DialogHeader className="min-w-0 pb-1">
            <DialogTitle className="truncate">
              Delete {deleteTarget ? versionDisplayName(liveTrack, deleteTarget) : "version"}?
            </DialogTitle>
          </DialogHeader>
          <p className="text-[13px] leading-5 text-muted-foreground">
            This permanently removes the version and its audio. Other versions of the track are
            unaffected.
          </p>
          <div className="flex justify-end gap-2 pt-5">
            <Button variant="ghost" size="lg" onClick={() => setDeleteTarget(null)}>
              Cancel
            </Button>
            <Button variant="destructive" size="lg" onClick={() => void confirmDelete()}>
              Delete
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}

function VersionCard({
  version,
  accent,
  name,
  number,
  isSelected,
  isPreviewing,
  isPreviewPlaying,
  isLoading,
  previewAudio,
  showsVisibility,
  canReorder,
  isDragging,
  menuItems,
  contextMenu,
  onSelect,
  onTogglePreview,
  onSeek,
  onDragStart,
  onDragOver,
  onDragEnd,
}: {
  version: TrackVersion
  accent: string
  name: string
  number: number
  isSelected: boolean
  isPreviewing: boolean
  isPreviewPlaying: boolean
  isLoading: boolean
  previewAudio: HTMLAudioElement | null
  showsVisibility: boolean
  canReorder: boolean
  isDragging: boolean
  menuItems: (version: TrackVersion) => ContextMenuItem[]
  contextMenu: ReturnType<typeof useContextMenu>
  onSelect: () => void
  onTogglePreview: () => void
  onSeek: (fraction: number) => void
  onDragStart: () => void
  onDragOver: () => void
  onDragEnd: () => void
}) {
  const cardRef = useRef<HTMLDivElement>(null)
  const previewingRef = useRef(isPreviewing)
  previewingRef.current = isPreviewing

  // Only the version currently auditioning shows a moving playhead.
  const getProgress = useCallback(() => {
    if (!previewingRef.current || !previewAudio) return 0
    const total = previewAudio.duration
    return Number.isFinite(total) && total > 0 ? previewAudio.currentTime / total : 0
  }, [previewAudio])

  const openMenu = (event: React.MouseEvent) => {
    const items = menuItems(version)
    if (items.length === 0) return
    contextMenu.open(event, items)
  }

  const openMenuAtButton = (event: React.MouseEvent<HTMLButtonElement>) => {
    event.stopPropagation()
    const items = menuItems(version)
    if (items.length === 0) return
    const rect = event.currentTarget.getBoundingClientRect()
    contextMenu.openAt(rect.left, rect.bottom + 4, items)
  }

  return (
    <div
      ref={cardRef}
      onContextMenu={openMenu}
      onDragOver={(event) => {
        event.preventDefault()
        onDragOver()
      }}
      className={cn(
        "group flex items-center gap-2 rounded-2xl border bg-card p-3 transition-[border-color,opacity,box-shadow]",
        isDragging && "opacity-40",
      )}
      style={isSelected ? { borderColor: accent, boxShadow: `0 0 0 1px ${accent}` } : undefined}
    >
      {canReorder && (
        <span
          draggable
          aria-label={`Reorder version ${number}`}
          onDragStart={(event) => {
            event.dataTransfer.effectAllowed = "move"
            // Firefox refuses to start a drag without payload.
            event.dataTransfer.setData("text/plain", version.id)
            // Drag the whole card, not just the little handle.
            if (cardRef.current) {
              const rect = cardRef.current.getBoundingClientRect()
              event.dataTransfer.setDragImage(cardRef.current, 24, rect.height / 2)
            }
            onDragStart()
          }}
          onDragEnd={onDragEnd}
          className="-ml-1 flex size-6 shrink-0 cursor-grab items-center justify-center text-muted-foreground/40 transition-colors hover:text-muted-foreground active:cursor-grabbing"
        >
          <GripVertical className="size-4" />
        </span>
      )}

      <button
        type="button"
        onClick={onSelect}
        aria-pressed={isSelected}
        className="flex min-w-0 flex-1 items-center gap-2.5 text-left"
      >
        <VersionBadge number={number} />
        <span className="flex min-w-0 flex-col gap-0.5">
          <span className="flex min-w-0 items-center gap-1.5">
            <span className="min-w-0 truncate text-[13px] font-semibold">{name}</span>
            {showsVisibility && !version.isPublic && (
              <EyeOff
                aria-label="Hidden from listeners"
                className="size-3 shrink-0 text-muted-foreground"
              />
            )}
          </span>
          <span className="text-[11px] text-muted-foreground">
            {formatDuration(version.duration)} • {formatFileSize(version.fileSize)}
          </span>
        </span>
      </button>

      <ScrollingWaveform
        trackID={version.id}
        waveform={version.waveform}
        getProgress={getProgress}
        onSeek={onSeek}
        duration={version.duration}
        visibleBars={22}
        barColor={BAR_COLOR}
        playedColor={PLAYED_COLOR}
        playheadColor={accent}
        className="h-7 w-[88px] shrink-0"
      />

      <button
        type="button"
        aria-label={isPreviewPlaying ? `Pause version ${number}` : `Preview version ${number}`}
        onClick={onTogglePreview}
        className="flex size-8 shrink-0 items-center justify-center rounded-full bg-secondary text-foreground transition hover:bg-secondary/70 active:scale-90"
      >
        {isLoading ? (
          <span className="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent" />
        ) : isPreviewPlaying ? (
          <Pause className="size-3.5 fill-current" strokeWidth={0} />
        ) : (
          <Play className="ml-0.5 size-3.5 fill-current" strokeWidth={0} />
        )}
      </button>

      {showsVisibility && (
        <button
          type="button"
          aria-label={`More options for version ${number}`}
          onClick={openMenuAtButton}
          className="flex size-8 shrink-0 items-center justify-center rounded-full text-muted-foreground transition hover:bg-muted hover:text-foreground"
        >
          <MoreHorizontal className="size-4" />
        </button>
      )}
    </div>
  )
}
