import { Layers, NotebookPen, NotebookText, Pencil, Play, Trash2 } from "lucide-react"
import { useState, type ReactNode } from "react"
import { useNavigate } from "react-router-dom"
import type { ContextMenuItem } from "@/components/context-menu"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { VersionsDialog } from "@/components/versions-dialog"
import { useAuth } from "@/hooks/use-auth"
import { useProject } from "@/hooks/use-projects"
import { deleteTrack, updateTrackTitle } from "@/lib/project-edits"
import { toast } from "@/lib/toast"
import type { Project, Track } from "@/lib/types"
import { hasMultipleVersions } from "@/lib/versions"
import { usePlayer } from "@/player/player-provider"

/**
 * The actions a single track exposes — used by the track row's context menu and
 * by the maximized player's options button, so both offer the same thing.
 * `dialogs` carries the rename/delete/versions surfaces and has to be rendered
 * by the caller.
 */
export function useTrackActions({
  track,
  project,
  onPlay,
  includePlay = true,
}: {
  track: Track
  project: Project
  /** Overrides the play action (e.g. shared pages join before playing). */
  onPlay?: (track: Track) => void
  /** Off for the player, where the track is already the one playing. */
  includePlay?: boolean
}): {
  menuItems: () => ContextMenuItem[]
  /** Opens the versions dialog directly, without going through the menu. */
  openVersions: () => void
  dialogs: ReactNode
} {
  const player = usePlayer()
  const { user } = useAuth()
  const navigate = useNavigate()
  const [renameOpen, setRenameOpen] = useState(false)
  const [renameTitle, setRenameTitle] = useState(track.title)
  const [renaming, setRenaming] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [versionsOpen, setVersionsOpen] = useState(false)

  const isActive = player.track?.id === track.id && player.project?.id === project.id
  const isOwnProject = !project.ownerID
  // Shared projects that aren't in the library yet (pre-join preview) have no
  // notes route, so the "View notes" item only appears once they're saved.
  const inLibrary = useProject(project.id) !== undefined

  const play = () => (onPlay ? onPlay(track) : player.play(track, project))

  const remove = async () => {
    if (!user) return
    try {
      if (isActive) player.stop()
      await deleteTrack(user.uid, project, track.id)
      toast.success(`Deleted “${track.title}”`)
    } catch (error) {
      console.error("deleting track failed", error)
      toast.error("Couldn't delete this track. Please try again.")
    }
  }

  const beginRename = () => {
    setRenameTitle(track.title)
    setRenaming(false)
    setRenameOpen(true)
  }

  const rename = async () => {
    const title = renameTitle.trim()
    if (!user || !title || renaming) return
    if (title === track.title) {
      setRenameOpen(false)
      return
    }
    setRenaming(true)
    try {
      await updateTrackTitle(user.uid, project, track.id, title)
      setRenameOpen(false)
    } catch (error) {
      console.error("renaming track failed", error)
      toast.error("Couldn't rename this track. Please try again.")
      setRenaming(false)
    }
  }

  const menuItems = (): ContextMenuItem[] => {
    const items: ContextMenuItem[] = includePlay
      ? [{ label: "Play", icon: <Play />, onSelect: play }]
      : []
    if (isOwnProject && user) {
      items.push(
        { label: "Rename", icon: <Pencil />, onSelect: beginRename },
        { label: "Versions", icon: <Layers />, onSelect: () => setVersionsOpen(true) },
        {
          label: "Edit notes",
          icon: <NotebookPen />,
          onSelect: () => navigate(`/project/${project.id}/notes/${track.id}`),
        },
        {
          label: "Delete",
          icon: <Trash2 />,
          destructive: true,
          onSelect: () => setConfirmDelete(true),
        },
      )
    } else if (inLibrary) {
      // Before a shared project is joined its audio streams through the public
      // link endpoint, which always serves the owner's active version.
      if (hasMultipleVersions(track)) {
        items.push({ label: "Versions", icon: <Layers />, onSelect: () => setVersionsOpen(true) })
      }
      items.push({
        label: "View notes",
        icon: <NotebookText />,
        onSelect: () => navigate(`/project/${project.id}/notes/${track.id}`),
      })
    }
    return items
  }

  const dialogs = (
    <>
      <Dialog
        open={renameOpen}
        onOpenChange={(open) => {
          setRenameOpen(open)
          if (!open) setRenaming(false)
        }}
      >
        <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
          <form
            onSubmit={(event) => {
              event.preventDefault()
              void rename()
            }}
          >
            <DialogHeader className="min-w-0 pb-1">
              <DialogTitle>Rename track</DialogTitle>
            </DialogHeader>
            <input
              autoFocus
              value={renameTitle}
              onChange={(event) => setRenameTitle(event.target.value)}
              placeholder="Track name"
              aria-label="Track name"
              maxLength={120}
              className="mt-4 h-11 w-full rounded-xl bg-secondary px-3.5 text-[15px] outline-none ring-brand/60 transition placeholder:text-muted-foreground/60 focus:ring-2"
            />
            <div className="flex justify-end gap-2 pt-5">
              <Button
                type="button"
                variant="ghost"
                size="lg"
                disabled={renaming}
                onClick={() => setRenameOpen(false)}
              >
                Cancel
              </Button>
              <Button type="submit" size="lg" disabled={!renameTitle.trim() || renaming}>
                {renaming ? "Renaming…" : "Rename"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

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

      {versionsOpen && (
        <VersionsDialog
          project={project}
          track={track}
          open={versionsOpen}
          onOpenChange={setVersionsOpen}
        />
      )}
    </>
  )

  return { menuItems, openVersions: () => setVersionsOpen(true), dialogs }
}
