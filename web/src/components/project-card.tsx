import {
  Ellipsis,
  LogOut,
  Pause,
  Pencil,
  Play,
  Share,
  Trash2,
} from "lucide-react"
import { useEffect, useState } from "react"
import { Link } from "react-router-dom"
import { toast } from "@/lib/toast"
import { useContextMenu, type ContextMenuItem } from "@/components/context-menu"
import { EditProjectDialog } from "@/components/edit-project-dialog"
import { COVER_RADIUS, CoverThumbnail } from "@/components/project-cover"
import { ShareDialog } from "@/components/share-dialog"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { useAuth } from "@/hooks/use-auth"
import { leaveSharedProject } from "@/lib/invites"
import { deleteProject } from "@/lib/project-edits"
import { trackCountText, type Project } from "@/lib/types"
import { usePlayer } from "@/player/player-provider"

export function ProjectCard({ project }: { project: Project }) {
  const { user } = useAuth()
  const contextMenu = useContextMenu()
  const player = usePlayer()
  const [contextMenuOpen, setContextMenuOpen] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [confirmAction, setConfirmAction] = useState<"delete" | "leave" | null>(null)
  const [performingAction, setPerformingAction] = useState(false)
  const [pressed, setPressed] = useState(false)
  const isOwnProject = !project.ownerID
  const isActiveProject = player.project?.id === project.id
  const showsPause = isActiveProject && player.isPlaying
  const firstPlayableTrack = project.tracks.find((track) => track.storagePath)

  // Only the cover itself scales on press; presses that start on an action
  // button leave the card at rest so just the small button reacts.
  const beginPress = (event: React.PointerEvent) => {
    if (event.button !== 0) return
    if ((event.target as HTMLElement).closest("button")) return
    setPressed(true)
  }

  useEffect(() => {
    if (!pressed) return
    const endPress = () => setPressed(false)
    window.addEventListener("pointerup", endPress)
    window.addEventListener("pointercancel", endPress)
    return () => {
      window.removeEventListener("pointerup", endPress)
      window.removeEventListener("pointercancel", endPress)
    }
  }, [pressed])

  const playOrPause = (event: React.MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    if (isActiveProject) {
      player.togglePlayPause()
      return
    }
    if (firstPlayableTrack) player.play(firstPlayableTrack, project)
  }

  const playFromMenu = () => {
    if (isActiveProject && player.isPlaying) return
    if (isActiveProject) {
      player.togglePlayPause()
    } else if (firstPlayableTrack) {
      player.play(firstPlayableTrack, project)
    }
  }

  const menuItems = (): ContextMenuItem[] => {
    const play: ContextMenuItem = {
      label: "Play",
      icon: <Play />,
      disabled: !firstPlayableTrack,
      onSelect: playFromMenu,
    }
    if (!isOwnProject) {
      return [
        play,
        {
          label: "Leave Project",
          icon: <LogOut />,
          destructive: true,
          onSelect: () => setConfirmAction("leave"),
        },
      ]
    }
    return [
      play,
      { label: "Edit", icon: <Pencil />, onSelect: () => setEditOpen(true) },
      { label: "Share", icon: <Share />, onSelect: () => setShareOpen(true) },
      {
        label: "Delete",
        icon: <Trash2 />,
        destructive: true,
        onSelect: () => setConfirmAction("delete"),
      },
    ]
  }

  const openActionsAtButton = (event: React.MouseEvent<HTMLButtonElement>) => {
    event.preventDefault()
    event.stopPropagation()
    const rect = event.currentTarget.getBoundingClientRect()
    contextMenu.openAt(rect.left, rect.bottom + 6, menuItems(), {
      onClose: () => setContextMenuOpen(false),
    })
    setContextMenuOpen(true)
  }

  const openActionsAtPointer = (event: React.MouseEvent) => {
    contextMenu.open(event, menuItems(), { onClose: () => setContextMenuOpen(false) })
    setContextMenuOpen(true)
  }

  const performConfirmedAction = async () => {
    if (!user || performingAction || !confirmAction) return
    setPerformingAction(true)
    try {
      if (isActiveProject) player.stop()
      if (confirmAction === "delete") {
        await deleteProject(user.uid, project)
      } else if (project.ownerID) {
        await leaveSharedProject(project.ownerID, project.id, user.uid)
      }
      setConfirmAction(null)
    } catch (error) {
      console.error(`${confirmAction} project failed`, error)
      toast(
        confirmAction === "delete"
          ? "Couldn't delete this project. Please try again."
          : "Couldn't leave this project. Please try again.",
      )
      setPerformingAction(false)
    }
  }

  return (
    <>
      <Link
        to={`/project/${project.id}`}
        className={`group block cursor-default select-none ${contextMenuOpen ? "project-card-menu-open" : ""}`}
        onContextMenu={openActionsAtPointer}
        onPointerDown={beginPress}
      >
        <div
          className={`relative aspect-square overflow-hidden ${COVER_RADIUS} transition-transform duration-300 ease-out ${
            pressed
              ? "scale-[0.98]"
              : contextMenuOpen
                ? "scale-[1.015]"
                : "group-hover:scale-[1.015]"
          }`}
        >
          <CoverThumbnail project={project} className={`h-full w-full ${COVER_RADIUS}`} />

          <button
            type="button"
            onClick={openActionsAtButton}
            aria-label={`More actions for ${project.name}`}
            aria-expanded={contextMenuOpen}
            className="project-card-action absolute bottom-2.5 left-2.5 flex size-8 items-center justify-center rounded-full bg-black/25 text-white shadow-sm backdrop-blur-md transition hover:bg-black/40 active:scale-90"
          >
            <Ellipsis className="size-4" />
          </button>

          {firstPlayableTrack && (
            <button
              type="button"
              onClick={playOrPause}
              aria-label={showsPause ? "Pause" : "Play"}
              data-active={showsPause}
              className="project-card-action absolute bottom-2.5 right-2.5 flex size-8 items-center justify-center rounded-full bg-black/25 text-white shadow-sm backdrop-blur-md transition-all duration-200 hover:bg-black/40 active:scale-90"
            >
              {showsPause ? (
                <Pause className="size-3.5 fill-current" strokeWidth={0} />
              ) : (
                <Play className="ml-0.5 size-3.5 fill-current" strokeWidth={0} />
              )}
            </button>
          )}
        </div>

        <div className="mt-2 flex flex-col gap-0.5 px-0.5">
          <span className="truncate text-sm font-semibold">{project.name}</span>
          <span className="text-xs text-muted-foreground">{trackCountText(project)}</span>
        </div>
      </Link>

      {isOwnProject && (
        <>
          <EditProjectDialog project={project} open={editOpen} onOpenChange={setEditOpen} />
          <ShareDialog project={project} open={shareOpen} onOpenChange={setShareOpen} />
        </>
      )}

      <Dialog
        open={confirmAction !== null}
        onOpenChange={(open) => {
          if (!open && !performingAction) setConfirmAction(null)
        }}
      >
        <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
          <DialogHeader className="min-w-0 pb-1">
            <DialogTitle className="truncate">
              {confirmAction === "delete"
                ? `Delete “${project.name}”?`
                : `Leave “${project.name}”?`}
            </DialogTitle>
          </DialogHeader>
          <p className="text-[13px] leading-5 text-muted-foreground">
            {confirmAction === "delete"
              ? "This will permanently delete the project and all of its tracks."
              : "This removes the project from your library on every device."}
          </p>
          <div className="flex justify-end gap-2 pt-5">
            <Button
              variant="ghost"
              size="lg"
              disabled={performingAction}
              onClick={() => setConfirmAction(null)}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              size="lg"
              disabled={performingAction}
              onClick={() => void performConfirmedAction()}
            >
              {performingAction
                ? confirmAction === "delete"
                  ? "Deleting…"
                  : "Leaving…"
                : confirmAction === "delete"
                  ? "Delete"
                  : "Leave"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </>
  )
}
