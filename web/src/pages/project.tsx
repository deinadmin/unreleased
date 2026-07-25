import {
  ChevronLeft,
  Ellipsis,
  LogOut,
  Pause,
  Pencil,
  Play,
  Plus,
  Share,
  Trash2,
} from "lucide-react"
import { useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { toast } from "sonner"
import { AppHeader } from "@/components/app-header"
import { useContextMenu, type ContextMenuItem } from "@/components/context-menu"
import { CoverDialog } from "@/components/cover-dialog"
import { EditProjectDialog } from "@/components/edit-project-dialog"
import { ProjectCover } from "@/components/project-cover"
import { ShareDialog } from "@/components/share-dialog"
import { TrackRow } from "@/components/track-row"
import { Button } from "@/components/ui/button"
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { Skeleton } from "@/components/ui/skeleton"
import { useAuth } from "@/hooks/use-auth"
import { useProject, useProjects } from "@/hooks/use-projects"
import { formatProjectDuration } from "@/lib/format"
import { leaveSharedProject } from "@/lib/invites"
import { projectBackLink } from "@/lib/project-navigation"
import { deleteProject, updateProjectName } from "@/lib/project-edits"
import { projectAccent, trackCountText, type Project } from "@/lib/types"
import { usePlayer } from "@/player/player-provider"
import { AudioDropzone } from "@/uploads/dropzone"
import { useUploads } from "@/uploads/uploads-provider"

export function ProjectPage() {
  const { projectId } = useParams()
  const location = useLocation()
  const navigate = useNavigate()
  const { user } = useAuth()
  const { loading } = useProjects()
  const project = useProject(projectId)
  const player = usePlayer()
  const contextMenu = useContextMenu()
  const { importFiles, isImporting } = useUploads()
  const [shareOpen, setShareOpen] = useState(false)
  const [coverOpen, setCoverOpen] = useState(false)
  const [editOpen, setEditOpen] = useState(false)
  const [deleteConfirmOpen, setDeleteConfirmOpen] = useState(false)
  const [leaveConfirmOpen, setLeaveConfirmOpen] = useState(false)
  const [isDeleting, setIsDeleting] = useState(false)
  const [isLeaving, setIsLeaving] = useState(false)
  const backLink = projectBackLink(location.state)

  if (loading && !project) {
    return (
      <div className="min-h-dvh">
        <AppHeader />
        <main className="mx-auto w-full max-w-2xl px-4 pt-10 sm:px-6">
          <div className="flex flex-col items-center gap-6">
            <Skeleton className="size-64 rounded-3xl" />
            <Skeleton className="h-6 w-48 rounded-md" />
            <Skeleton className="h-4 w-32 rounded-md" />
          </div>
        </main>
      </div>
    )
  }

  if (!project) {
    return (
      <div className="min-h-dvh">
        <AppHeader />
        <main className="flex flex-col items-center pt-[20vh] text-muted-foreground">
          <p className="text-[15px]">Project not found</p>
          <Link
            to={backLink.to}
            className="pt-3 text-[15px] font-semibold text-foreground hover:opacity-70"
          >
            Back to {backLink.label.toLowerCase()}
          </Link>
        </main>
      </div>
    )
  }

  const accent = projectAccent(project)
  const isActiveProject = player.project?.id === project.id
  const isProjectPlaying = isActiveProject && player.isPlaying
  const totalDuration = project.tracks.reduce((sum, t) => sum + t.duration, 0)
  const hasPlayableTracks = project.tracks.some((t) => t.storagePath)

  const playOrPause = () => {
    if (isActiveProject) {
      player.togglePlayPause()
      return
    }
    const first = project.tracks.find((t) => t.storagePath)
    if (first) player.play(first, project)
  }

  // Editing and uploads are only available for the user's own projects.
  const isOwnProject = !project.ownerID
  const canUpload = isOwnProject
  const addFiles = (files: File[]) =>
    void importFiles(files, { kind: "existing", projectID: project.id })
  const leaveProject = async () => {
    if (!user || !project.ownerID || isLeaving) return
    setIsLeaving(true)
    try {
      if (isActiveProject) player.stop()
      await leaveSharedProject(project.ownerID, project.id, user.uid)
      setLeaveConfirmOpen(false)
      navigate("/", { replace: true })
    } catch {
      toast("Couldn't leave this project. Please try again.")
      setIsLeaving(false)
    }
  }
  const removeProject = async () => {
    if (!user || !isOwnProject || isDeleting) return
    setIsDeleting(true)
    try {
      if (isActiveProject) player.stop()
      await deleteProject(user.uid, project)
      setDeleteConfirmOpen(false)
      navigate("/", { replace: true })
    } catch (error) {
      console.error("deleting project failed", error)
      toast("Couldn't delete this project. Please try again.")
      setIsDeleting(false)
    }
  }

  const menuItems = (): ContextMenuItem[] =>
    isOwnProject
      ? [
          { label: "Edit", icon: <Pencil />, onSelect: () => setEditOpen(true) },
          {
            label: "Delete",
            icon: <Trash2 />,
            destructive: true,
            onSelect: () => setDeleteConfirmOpen(true),
          },
        ]
      : [
          {
            label: "Leave Project",
            icon: <LogOut />,
            destructive: true,
            onSelect: () => setLeaveConfirmOpen(true),
          },
        ]

  const openActionsAtButton = (event: React.MouseEvent<HTMLButtonElement>) => {
    const rect = event.currentTarget.getBoundingClientRect()
    contextMenu.openAt(rect.left, rect.bottom + 6, menuItems())
  }

  return (
    <AudioDropzone
      disabled={!canUpload}
      overlayLabel={`Drop audio files to add to “${project.name}”`}
      onFiles={addFiles}
    >
      {(openPicker) => (
        <div className="project-detail-page min-h-dvh">
          <AppHeader />

          <main className="project-detail-main mx-auto w-full max-w-2xl px-4 pb-40 sm:px-6">
            <div className="flex h-12 items-center">
              <Link
                to={backLink.to}
                className="relative z-10 -ml-2 flex items-center gap-0.5 rounded-lg px-2 py-1.5 text-[15px] font-medium text-muted-foreground transition hover:text-foreground"
              >
                <ChevronLeft className="size-4.5" />
                {backLink.label}
              </Link>
            </div>

            <div className="project-detail-layout">
              <section className="project-detail-summary rise-in flex flex-col items-center pt-4">
                {isOwnProject ? (
                  <button
                    type="button"
                    aria-label="Edit cover"
                    onClick={() => setCoverOpen(true)}
                    className="project-detail-cover w-56 cursor-default transition duration-300 hover:opacity-95 active:scale-[0.99] sm:w-64"
                  >
                    <ProjectCover
                      project={project}
                      isPlaying={isProjectPlaying}
                      className="w-full"
                    />
                  </button>
                ) : (
                  <ProjectCover
                    project={project}
                    isPlaying={isProjectPlaying}
                    className="project-detail-cover w-56 sm:w-64"
                  />
                )}

                {isOwnProject ? (
                  <EditableTitle project={project} />
                ) : (
                  <h1 className="max-w-full truncate pt-7 text-center text-[22px] font-bold">
                    {project.name}
                  </h1>
                )}
                <p className="pt-1 text-[13px] text-muted-foreground">
                  {trackCountText(project)} •{" "}
                  {formatProjectDuration(totalDuration, project.tracks.length)}
                  {project.ownerUsername ? ` • by @${project.ownerUsername}` : ""}
                </p>

                <div className="mt-5 flex items-center gap-3">
                  {hasPlayableTracks && (
                    <button
                      type="button"
                      onClick={playOrPause}
                      className="flex h-11 items-center gap-2 rounded-full px-7 text-[15px] font-bold text-white shadow-md transition hover:brightness-105 active:scale-[0.98]"
                      style={{ background: accent }}
                    >
                      {isProjectPlaying ? (
                        <>
                          <Pause className="size-4 fill-current" strokeWidth={0} />
                          Pause
                        </>
                      ) : (
                        <>
                          <Play className="size-4 fill-current" strokeWidth={0} />
                          Play
                        </>
                      )}
                    </button>
                  )}

                  <button
                    type="button"
                    aria-label="Share project"
                    onClick={() => setShareOpen(true)}
                    className="flex size-11 items-center justify-center rounded-full border border-foreground/6 bg-secondary shadow-sm transition hover:bg-secondary/70 active:scale-95"
                  >
                    <Share className="size-4.5" />
                  </button>

                  {canUpload && (
                    <button
                      type="button"
                      aria-label="Add tracks"
                      disabled={isImporting}
                      onClick={openPicker}
                      className="flex size-11 items-center justify-center rounded-full border border-foreground/6 bg-secondary shadow-sm transition hover:bg-secondary/70 active:scale-95 disabled:opacity-50"
                    >
                      <Plus className="size-4.5" />
                    </button>
                  )}

                  <button
                    type="button"
                    aria-label="More project actions"
                    onClick={openActionsAtButton}
                    className="flex size-11 items-center justify-center rounded-full border border-foreground/6 bg-secondary shadow-sm transition hover:bg-secondary/70 active:scale-95"
                  >
                    <Ellipsis className="size-4.5" />
                  </button>
                </div>
              </section>

              <section
                className="project-detail-tracks rise-in pt-8"
                style={{ animationDelay: "0.08s" }}
              >
                {project.tracks.length === 0 ? (
                  <p className="pt-8 text-center text-[15px] text-muted-foreground">
                    No tracks yet — drop audio files here or tap + to add some.
                  </p>
                ) : (
                  <div className="flex flex-col">
                    {project.tracks.map((track, index) => (
                      <TrackRow
                        key={track.id}
                        track={track}
                        index={index + 1}
                        project={project}
                        accent={accent}
                      />
                    ))}
                  </div>
                )}
              </section>
            </div>
          </main>

          <ShareDialog project={project} open={shareOpen} onOpenChange={setShareOpen} />
          {isOwnProject && (
            <>
              <CoverDialog project={project} open={coverOpen} onOpenChange={setCoverOpen} />
              <EditProjectDialog
                project={project}
                open={editOpen}
                onOpenChange={setEditOpen}
              />
            </>
          )}

          <Dialog open={deleteConfirmOpen} onOpenChange={setDeleteConfirmOpen}>
            <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
              <DialogHeader className="min-w-0 pb-1">
                <DialogTitle className="truncate">Delete “{project.name}”?</DialogTitle>
              </DialogHeader>
              <p className="text-[13px] leading-5 text-muted-foreground">
                This will permanently delete the project and all of its tracks.
              </p>
              <div className="flex justify-end gap-2 pt-5">
                <Button
                  variant="ghost"
                  size="lg"
                  disabled={isDeleting}
                  onClick={() => setDeleteConfirmOpen(false)}
                >
                  Cancel
                </Button>
                <Button
                  variant="destructive"
                  size="lg"
                  disabled={isDeleting}
                  onClick={() => void removeProject()}
                >
                  {isDeleting ? "Deleting…" : "Delete"}
                </Button>
              </div>
            </DialogContent>
          </Dialog>

          <Dialog open={leaveConfirmOpen} onOpenChange={setLeaveConfirmOpen}>
            <DialogContent className="rounded-3xl p-6 sm:max-w-sm">
              <DialogHeader className="min-w-0 pb-1">
                <DialogTitle className="truncate">Leave “{project.name}”?</DialogTitle>
              </DialogHeader>
              <p className="text-[13px] leading-5 text-muted-foreground">
                This removes the project from your library on every device.
              </p>
              <div className="flex justify-end gap-2 pt-5">
                <Button
                  variant="ghost"
                  size="lg"
                  disabled={isLeaving}
                  onClick={() => setLeaveConfirmOpen(false)}
                >
                  Cancel
                </Button>
                <Button
                  variant="destructive"
                  size="lg"
                  disabled={isLeaving}
                  onClick={() => void leaveProject()}
                >
                  {isLeaving ? "Leaving…" : "Leave"}
                </Button>
              </div>
            </DialogContent>
          </Dialog>
        </div>
      )}
    </AudioDropzone>
  )
}

/**
 * The project title as an invisible in-place editor: clicking puts the caret
 * straight into the heading; blur (or Enter) commits the new name.
 */
function EditableTitle({ project }: { project: Project }) {
  const { user } = useAuth()

  const commit = (element: HTMLHeadingElement) => {
    const name = (element.textContent ?? "").trim() || "untitled project"
    element.textContent = name
    if (!user || name === project.name) return
    updateProjectName(user.uid, project, name).catch(() => {
      element.textContent = project.name
      toast("Couldn't rename the project. Please try again.")
    })
  }

  return (
    <h1
      // Remount when the name changes externally so React and the
      // contentEditable DOM never fight over the text node.
      key={project.name}
      contentEditable
      suppressContentEditableWarning
      spellCheck={false}
      role="textbox"
      aria-label="Project name"
      className="max-w-full cursor-text truncate rounded-md px-1 pt-7 text-center text-[22px] font-bold outline-none focus:overflow-x-auto focus:text-clip"
      onBlur={(event) => commit(event.currentTarget)}
      onKeyDown={(event) => {
        if (event.key === "Enter") {
          event.preventDefault()
          event.currentTarget.blur()
        } else if (event.key === "Escape") {
          event.currentTarget.textContent = project.name
          event.currentTarget.blur()
        }
      }}
      onPaste={(event) => {
        event.preventDefault()
        const text = event.clipboardData.getData("text/plain").replace(/\s+/g, " ")
        document.execCommand("insertText", false, text)
      }}
    >
      {project.name}
    </h1>
  )
}
