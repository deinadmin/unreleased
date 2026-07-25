import { Plus } from "lucide-react"
import { useEffect, useState } from "react"
import { useNavigate } from "react-router-dom"
import { AppHeader } from "@/components/app-header"
import { AppMark } from "@/components/app-mark"
import { NewProjectDialog } from "@/components/new-project-dialog"
import { ProjectCard } from "@/components/project-card"
import { Skeleton } from "@/components/ui/skeleton"
import { useProjects } from "@/hooks/use-projects"
import { isTypingTarget } from "@/lib/utils"
import { AudioDropzone } from "@/uploads/dropzone"
import { useUploads } from "@/uploads/uploads-provider"

export function LibraryPage() {
  const { projects, loading } = useProjects()
  const { importFiles, isImporting } = useUploads()
  const [newProjectOpen, setNewProjectOpen] = useState(false)
  const navigate = useNavigate()

  const createProjectFromFiles = async (files: File[]) => {
    const projectID = await importFiles(files, { kind: "new" })
    if (projectID) navigate(`/project/${projectID}`)
  }

  // "N" opens the new-project dialog (mirrors the header button).
  const showsNewProjectButton = !loading && projects.length > 0
  useEffect(() => {
    if (!showsNewProjectButton) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key.toLowerCase() !== "n" || event.repeat || event.defaultPrevented) return
      if (event.metaKey || event.ctrlKey || event.altKey) return
      if (isTypingTarget(event.target)) return
      event.preventDefault()
      setNewProjectOpen(true)
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [showsNewProjectButton])

  return (
    <AudioDropzone
      overlayLabel="Drop audio files to start a new project"
      onFiles={(files) => void createProjectFromFiles(files)}
    >
      {(openPicker) => (
        <div className="min-h-dvh">
          <AppHeader />

          <main className="mx-auto w-full max-w-6xl px-4 pb-36 pt-6 sm:px-6">
            {loading ? (
              <LibrarySkeleton />
            ) : projects.length === 0 ? (
              <EmptyState onImport={openPicker} importing={isImporting} />
            ) : (
              <>
                <div className="flex items-center justify-between pb-5">
                  <h1 className="text-[22px] font-bold">Library</h1>
                  <button
                    type="button"
                    onClick={() => setNewProjectOpen(true)}
                    title="New project (N)"
                    aria-keyshortcuts="n"
                    className="flex h-9 items-center gap-1.5 rounded-full bg-brand px-4 text-[13px] font-semibold text-white transition hover:bg-brand/85 active:scale-[0.98]"
                  >
                    <Plus className="size-3.5" />
                    New project
                  </button>
                </div>

                <div className="grid grid-cols-2 gap-x-4 gap-y-6 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
                  {projects.map((project, i) => (
                    <div
                      key={project.id}
                      className="rise-in"
                      style={{ animationDelay: `${Math.min(i, 12) * 0.03}s` }}
                    >
                      <ProjectCard project={project} />
                    </div>
                  ))}
                </div>
              </>
            )}
          </main>

          <NewProjectDialog
            open={newProjectOpen}
            onOpenChange={setNewProjectOpen}
            onCreated={(projectID) => navigate(`/project/${projectID}`)}
          />
        </div>
      )}
    </AudioDropzone>
  )
}

function LibrarySkeleton() {
  return (
    <div className="grid grid-cols-2 gap-x-4 gap-y-6 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
      {Array.from({ length: 10 }).map((_, i) => (
        <div key={i} className="flex flex-col gap-2">
          <Skeleton className="aspect-square rounded-2xl" />
          <Skeleton className="h-4 w-3/4 rounded-md" />
          <Skeleton className="h-3 w-1/3 rounded-md" />
        </div>
      ))}
    </div>
  )
}

function EmptyState({ onImport, importing }: { onImport: () => void; importing: boolean }) {
  return (
    <div className="rise-in flex flex-col items-center pt-[12vh] text-center">
      <AppMark className="size-52" />
      <h2 className="pt-9 text-[22px] font-bold">Start your first project</h2>
      <p className="max-w-70 pt-2 text-[15px] text-muted-foreground">
        Create a home for your work-in-progress music. Drop audio files anywhere, or import to
        get started.
      </p>
      <button
        type="button"
        disabled={importing}
        onClick={onImport}
        className="mt-7 flex h-12 items-center gap-2 rounded-full bg-foreground px-7 text-[15px] font-bold text-background transition hover:opacity-90 active:scale-[0.98] disabled:opacity-50"
      >
        <Plus className="size-4" />
        Import tracks
      </button>
    </div>
  )
}
