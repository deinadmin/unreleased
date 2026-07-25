import { MoreHorizontal, NotebookPen, NotebookText, Play, Trash2 } from "lucide-react"
import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { toast } from "sonner"
import { useContextMenu, type ContextMenuItem } from "@/components/context-menu"
import { PlayingBars } from "@/components/playing-bars"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import { useProject } from "@/hooks/use-projects"
import { formatDuration, formatFileSize, formatRelativeDate } from "@/lib/format"
import { deleteTrack } from "@/lib/project-edits"
import type { Project, Track } from "@/lib/types"
import { usePlayer } from "@/player/player-provider"

export function TrackRow({
  track,
  index,
  project,
  accent,
  onPlay,
}: {
  track: Track
  index: number
  project: Project
  accent: string
  /** Overrides the default play action (e.g. shared pages join before playing). */
  onPlay?: (track: Track) => void
}) {
  const player = usePlayer()
  const { user } = useAuth()
  const navigate = useNavigate()
  const contextMenu = useContextMenu()
  const [confirmDelete, setConfirmDelete] = useState(false)
  const isActive = player.track?.id === track.id && player.project?.id === project.id
  const versionNumber =
    track.versions.length > 1
      ? track.versions.length -
        Math.max(0, track.versions.findIndex((v) => v.id === track.activeVersionID))
      : null

  const play = () => (onPlay ? onPlay(track) : player.play(track, project))
  const isOwnProject = !project.ownerID
  // Shared projects that aren't in the library yet (pre-join preview) have no
  // notes route, so the "View notes" item only appears once they're saved.
  const inLibrary = useProject(project.id) !== undefined

  const remove = async () => {
    if (!user) return
    try {
      if (isActive) player.stop()
      await deleteTrack(user.uid, project, track.id)
    } catch (error) {
      console.error("deleting track failed", error)
      toast("Couldn't delete this track. Please try again.")
    }
  }

  const contextMenuItems = (): ContextMenuItem[] => {
    const items: ContextMenuItem[] = [{ label: "Play", icon: <Play />, onSelect: play }]
    if (isOwnProject && user) {
      items.push(
        {
          label: "Edit notes",
          icon: <NotebookPen />,
          onSelect: () => navigate(`/project/${project.id}/notes/${track.id}`),
        },
        { label: "Delete", icon: <Trash2 />, destructive: true, onSelect: () => setConfirmDelete(true) },
      )
    } else if (inLibrary) {
      items.push({
        label: "View notes",
        icon: <NotebookText />,
        onSelect: () => navigate(`/project/${project.id}/notes/${track.id}`),
      })
    }
    return items
  }

  const openContextMenu = (event: React.MouseEvent) => {
    contextMenu.open(event, contextMenuItems())
  }

  const openMobileMenu = (event: React.MouseEvent<HTMLButtonElement>) => {
    event.stopPropagation()
    const rect = event.currentTarget.getBoundingClientRect()
    contextMenu.openAt(rect.right, rect.bottom + 4, contextMenuItems())
  }

  return (
    <>
    <div
      onContextMenu={openContextMenu}
      className="track-row group relative flex w-full items-center overflow-hidden rounded-xl transition-colors hover:bg-muted/60"
    >
      <button
        type="button"
        onClick={play}
        disabled={!track.storagePath}
        className="flex min-w-0 flex-1 items-center gap-3 rounded-xl px-3 py-3 text-left disabled:cursor-default disabled:opacity-50"
      >
        <span className="flex w-7 shrink-0 items-center justify-center">
          {isActive && player.isPlaying ? (
            <PlayingBars color={accent} />
          ) : (
            <span className="text-sm font-medium tabular-nums text-muted-foreground">{index}</span>
          )}
        </span>

        <span className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="flex items-center gap-1.5">
            <span
              className="truncate text-[15px] font-semibold"
              style={isActive ? { color: accent } : undefined}
            >
              {track.title}
            </span>
            {versionNumber !== null && (
              <span className="shrink-0 rounded-md bg-muted px-1.5 py-0.5 text-[10px] font-bold text-muted-foreground">
                v{versionNumber}
              </span>
            )}
          </span>
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <span>{formatRelativeDate(track.addedDate)}</span>
            <span>•</span>
            <span>{formatFileSize(track.fileSize)}</span>
          </span>
        </span>

        <span className="track-row-duration shrink-0 text-xs tabular-nums text-muted-foreground">
          {formatDuration(track.duration)}
        </span>
      </button>

      <button
        type="button"
        aria-label={`More options for ${track.title}`}
        onClick={openMobileMenu}
        className="track-row-action absolute right-2.5 flex size-10 shrink-0 items-center justify-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground"
      >
        <MoreHorizontal className="size-5" />
      </button>
    </div>

    <Dialog open={confirmDelete} onOpenChange={setConfirmDelete}>
      <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
        <DialogHeader className="min-w-0 pb-1">
          <DialogTitle className="truncate">Delete “{track.title}”?</DialogTitle>
        </DialogHeader>
        <p className="text-[13px] leading-5 text-muted-foreground">
          This removes the track and its audio files from the project. This can't be undone.
        </p>
        <div className="flex justify-end gap-2 pt-5">
          <Button variant="ghost" size="lg" onClick={() => setConfirmDelete(false)}>
            Cancel
          </Button>
          <Button
            variant="destructive"
            size="lg"
            onClick={() => {
              setConfirmDelete(false)
              void remove()
            }}
          >
            Delete
          </Button>
        </div>
      </DialogContent>
    </Dialog>
    </>
  )
}
