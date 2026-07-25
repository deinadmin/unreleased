import { ChevronLeft } from "lucide-react"
import { useCallback, useEffect, useRef, useState } from "react"
import { Link, useParams } from "react-router-dom"
import { toast } from "sonner"
import { AppHeader } from "@/components/app-header"
import { Skeleton } from "@/components/ui/skeleton"
import { useAuth } from "@/hooks/use-auth"
import { useProject, useProjects } from "@/hooks/use-projects"
import { updateTrackNotes } from "@/lib/project-edits"

/**
 * Full-page notes editor for a track (own projects only). The textarea is
 * borderless so the notes read like page content, and edits auto-save shortly
 * after typing stops (plus a flush on leave).
 */
export function TrackNotesPage() {
  const { projectId, trackId } = useParams()
  const { loading } = useProjects()
  const project = useProject(projectId)
  const track = project?.tracks.find((t) => t.id === trackId)
  const { user } = useAuth()
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  // null = untouched draft; falls back to the track's stored notes.
  const [draft, setDraft] = useState<string | null>(null)

  // Focus the editor with the cursor at the end once the track has loaded.
  const ready = Boolean(project && track)
  useEffect(() => {
    if (!ready) return
    const el = textareaRef.current
    if (!el) return
    el.focus()
    el.setSelectionRange(el.value.length, el.value.length)
  }, [ready])

  const persist = useCallback(
    async (notes: string) => {
      if (!user || !project || !track) return
      try {
        await updateTrackNotes(user.uid, project, track.id, notes)
      } catch (error) {
        console.error("saving notes failed", error)
        toast("Couldn't save the notes. Check your connection.")
      }
    },
    [user, project, track],
  )

  // Auto-save once typing pauses.
  useEffect(() => {
    if (draft === null) return
    const timer = setTimeout(() => void persist(draft), 800)
    return () => clearTimeout(timer)
  }, [draft, persist])

  // Flush any pending draft when leaving the page.
  const latest = useRef<{ draft: string | null; persist: (notes: string) => Promise<void> }>({
    draft,
    persist,
  })
  latest.current = { draft, persist }
  useEffect(
    () => () => {
      const { draft: pending, persist: flush } = latest.current
      if (pending !== null) void flush(pending)
    },
    [],
  )

  if (loading && !track) {
    return (
      <div className="min-h-dvh">
        <AppHeader />
        <main className="mx-auto w-full max-w-2xl px-4 pt-10 sm:px-6">
          <Skeleton className="h-6 w-48 rounded-md" />
          <Skeleton className="mt-6 h-64 w-full rounded-2xl" />
        </main>
      </div>
    )
  }

  if (!project || !track) {
    return (
      <div className="min-h-dvh">
        <AppHeader />
        <main className="flex flex-col items-center pt-[20vh] text-muted-foreground">
          <p className="text-[15px]">Track not found</p>
          <Link to="/" className="pt-3 text-[15px] font-semibold text-foreground hover:opacity-70">
            Back to library
          </Link>
        </main>
      </div>
    )
  }

  const value = draft ?? track.notes

  return (
    <div className="min-h-dvh">
      <AppHeader />

      <main className="mx-auto flex w-full max-w-2xl flex-col px-4 pb-40 sm:px-6">
        <div className="flex h-12 items-center">
          <Link
            to={`/project/${project.id}`}
            className="-ml-2 flex items-center gap-0.5 rounded-lg px-2 py-1.5 text-[15px] font-medium text-muted-foreground transition hover:text-foreground"
          >
            <ChevronLeft className="size-4.5" />
            {project.name}
          </Link>
        </div>

        <section className="rise-in pt-4">
          <h1 className="text-[22px] font-bold">Notes</h1>
          <p className="pt-1 text-[13px] text-muted-foreground">{track.title}</p>

          <textarea
            ref={textareaRef}
            value={value}
            placeholder="Start to type…"
            onChange={(event) => setDraft(event.target.value)}
            className="mt-8 min-h-[55vh] w-full resize-none border-none bg-transparent p-0 text-[15px] leading-7 outline-none placeholder:text-muted-foreground/60"
          />
        </section>
      </main>
    </div>
  )
}
