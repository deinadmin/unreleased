import { doc, onSnapshot } from "firebase/firestore"
import { Pause, Play, Plus } from "lucide-react"
import { useEffect, useState } from "react"
import { Navigate, useLocation, useNavigate, useParams } from "react-router-dom"
import { toast } from "@/lib/toast"
import { AppHeader } from "@/components/app-header"
import { AppMark } from "@/components/app-mark"
import { CloudProjectCover, ProjectCover } from "@/components/project-cover"
import { TrackRow } from "@/components/track-row"
import { Skeleton } from "@/components/ui/skeleton"
import { useAuth } from "@/hooks/use-auth"
import { useProject, useProjects } from "@/hooks/use-projects"
import { decodeProject } from "@/lib/codec"
import { db } from "@/lib/firebase"
import { formatProjectDuration } from "@/lib/format"
import {
  acceptInvite,
  fetchPreview,
  hasPendingInvite,
  normalizeProjectID,
  publicTrackURL,
} from "@/lib/invites"
import {
  projectAccent,
  sharedPlayableProject,
  trackCountText,
  type Project,
  type ProjectPreview,
} from "@/lib/types"
import { usePlayer } from "@/player/player-provider"

type PageState =
  | { phase: "loading" }
  /** Link disabled (or guest sessions unavailable) — sign in to check access. */
  | { phase: "auth-required"; preview: ProjectPreview | null }
  | { phase: "not-found" }
  /** Signed-in user who can't read the project yet but may join. */
  | { phase: "invite"; preview: ProjectPreview; canJoin: boolean }
  | { phase: "ready"; project: Project }

export function SharedProjectPage() {
  const { ownerId = "", projectId: rawProjectID = "" } = useParams()
  const projectID = normalizeProjectID(rawProjectID)
  const { user, initializing, isSignedIn, displayUsername, signInAsGuest } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()
  const player = usePlayer()
  const { materializeSharedProject } = useProjects()
  const inLibrary = useProject(projectID) !== undefined
  const [state, setState] = useState<PageState>({ phase: "loading" })
  const [accepting, setAccepting] = useState(false)

  useEffect(() => {
    if (initializing || !ownerId || !projectID) return

    // Guests get a silent anonymous session so security rules can evaluate.
    if (!user) {
      signInAsGuest().catch(() => setState({ phase: "auth-required", preview: null }))
      return
    }

    let cancelled = false
    let unsubscribe: (() => void) | undefined

    const start = async () => {
      const preview = await fetchPreview(ownerId, projectID)
      if (cancelled) return
      unsubscribe = onSnapshot(
        doc(db, "users", ownerId, "projects", projectID),
        async (snapshot) => {
          if (cancelled) return
          if (!snapshot.exists()) {
            setState({ phase: "not-found" })
            return
          }
          const decoded = await decodeProject(snapshot.data())
          if (cancelled || !decoded) return
          const playable = sharedPlayableProject({ ...decoded, ownerID: ownerId })
          setState({
            phase: "ready",
            project: {
              ...playable,
              tracks: playable.tracks.map((track) => ({
                ...track,
                storagePath: track.storagePath
                  ? publicTrackURL(ownerId, projectID, track.id)
                  : undefined,
              })),
            },
          })
        },
        async () => {
          // Permission denied: link off (or never shared).
          if (cancelled) return
          if (!preview) {
            setState({ phase: "not-found" })
            return
          }
          if (!isSignedIn) {
            setState({ phase: "auth-required", preview })
            return
          }
          const pending = await hasPendingInvite(ownerId, projectID, user.uid)
          if (!cancelled) {
            setState({ phase: "invite", preview, canJoin: preview.linkEnabled || pending })
          }
        },
      )
    }
    void start()
    return () => {
      cancelled = true
      unsubscribe?.()
    }
  }, [initializing, user, isSignedIn, ownerId, projectID, signInAsGuest])

  // Owner or already-accepted: the project view handles it.
  if (inLibrary) {
    return <Navigate to={`/project/${projectID}`} replace state={location.state} />
  }

  const join = async () => {
    if (!user || !isSignedIn) throw new Error("not signed in")
    await acceptInvite(ownerId, projectID, user.uid, displayUsername)
  }

  const saveToLibrary = async () => {
    setAccepting(true)
    let joined = false
    try {
      await join()
      joined = true
      const loadedProject = await materializeSharedProject(ownerId, projectID)
      if (!loadedProject) {
        toast("You joined this project, but it is still syncing to your library.")
        return
      }
      navigate(`/project/${projectID}`, { replace: true, state: location.state })
    } catch {
      toast(
        joined
          ? "You joined this project, but it couldn't be loaded yet. Please refresh your library."
          : "Couldn't join this project. The invite may have been withdrawn.",
      )
    } finally {
      setAccepting(false)
    }
  }

  const signInPath = `/welcome?next=/shared/${ownerId}/${rawProjectID.toLowerCase()}`

  return (
    <div className="min-h-dvh">
      <AppHeader />
      <main className="mx-auto w-full max-w-2xl px-4 pb-40 sm:px-6">
        {state.phase === "loading" && (
          <div className="flex flex-col items-center gap-6 pt-16">
            <Skeleton className="size-56 rounded-3xl" />
            <Skeleton className="h-6 w-48 rounded-md" />
            <Skeleton className="h-4 w-32 rounded-md" />
          </div>
        )}

        {state.phase === "not-found" && (
          <CenteredMessage
            title="Project not found"
            body="This link may be wrong, or the project is no longer shared."
          />
        )}

        {state.phase === "auth-required" && (
          <CenteredMessage
            title="Project not found"
            body="This link may be wrong, or the project is no longer shared."
          />
        )}

        {state.phase === "invite" && (
          <InviteCard
            preview={state.preview}
            canJoin={state.canJoin}
            accepting={accepting}
            onAccept={() => void saveToLibrary()}
          />
        )}

        {state.phase === "ready" && (
          <SharedListenView
            project={state.project}
            player={player}
            isSignedIn={isSignedIn}
            accepting={accepting}
            onSave={() => (isSignedIn ? void saveToLibrary() : navigate(signInPath))}
            onPlay={(play) => play()}
          />
        )}
      </main>
    </div>
  )
}

function CenteredMessage({
  title,
  body,
  children,
}: {
  title: string
  body: string
  children?: React.ReactNode
}) {
  return (
    <div className="rise-in flex flex-col items-center pt-[16vh] text-center">
      <AppMark className="size-20 opacity-90" />
      <h1 className="pt-7 text-[22px] font-bold">{title}</h1>
      <p className="max-w-72 pt-2 text-[15px] text-muted-foreground">{body}</p>
      {children}
    </div>
  )
}

function InviteCard({
  preview,
  canJoin,
  accepting,
  onAccept,
}: {
  preview: ProjectPreview
  canJoin: boolean
  accepting: boolean
  onAccept: () => void
}) {
  return (
    <div className="rise-in flex flex-col items-center pt-[10vh] text-center">
      <CloudProjectCover
        name={preview.name}
        gradient={preview.gradient}
        coverStoragePath={preview.coverStoragePath}
        className="size-40 shadow-lg"
      />
      <h1 className="max-w-full truncate pt-7 text-[22px] font-bold">{preview.name}</h1>
      {preview.ownerUsername && (
        <p className="pt-1 text-[13px] text-muted-foreground">
          @{preview.ownerUsername} invited you to listen
        </p>
      )}
      {canJoin ? (
        <button
          type="button"
          disabled={accepting}
          onClick={onAccept}
          className="mt-7 flex h-12 items-center gap-2 rounded-full bg-foreground px-8 text-[15px] font-bold text-background transition hover:opacity-90 active:scale-[0.98] disabled:opacity-50"
        >
          {accepting ? "Joining…" : "Save to library"}
        </button>
      ) : (
        <p className="mt-7 max-w-72 text-sm text-muted-foreground">
          This project's share link is turned off. Ask @{preview.ownerUsername || "the owner"} for
          an invite.
        </p>
      )}
    </div>
  )
}

function SharedListenView({
  project,
  player,
  isSignedIn,
  accepting,
  onSave,
  onPlay,
}: {
  project: Project
  player: ReturnType<typeof usePlayer>
  isSignedIn: boolean
  accepting: boolean
  onSave: () => void
  onPlay: (play: () => void) => void
}) {
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
    if (first) onPlay(() => player.play(first, project))
  }

  return (
    <>
      <section className="rise-in flex flex-col items-center pt-10">
        <ProjectCover project={project} isPlaying={isProjectPlaying} className="w-56 sm:w-64" />

        <h1 className="max-w-full truncate pt-7 text-center text-[22px] font-bold">
          {project.name}
        </h1>
        <p className="pt-1 text-[13px] text-muted-foreground">
          {trackCountText(project)} • {formatProjectDuration(totalDuration, project.tracks.length)}
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
                  <Pause className="size-4 fill-current" strokeWidth={0} /> Pause
                </>
              ) : (
                <>
                  <Play className="size-4 fill-current" strokeWidth={0} /> Play
                </>
              )}
            </button>
          )}

          <button
            type="button"
            disabled={accepting}
            onClick={onSave}
            className="flex h-11 items-center gap-1.5 rounded-full border border-foreground/6 bg-secondary px-5 text-[14px] font-semibold transition hover:bg-secondary/70 active:scale-[0.98] disabled:opacity-50"
          >
            <Plus className="size-4" />
            {accepting ? "Saving…" : isSignedIn ? "Save to library" : "Sign in to save"}
          </button>
        </div>
      </section>

      <section className="rise-in pt-8" style={{ animationDelay: "0.08s" }}>
        {project.tracks.length === 0 ? (
          <p className="pt-8 text-center text-[15px] text-muted-foreground">No tracks yet.</p>
        ) : (
          <div className="flex flex-col">
            {project.tracks.map((track, index) => (
              <TrackRow
                key={track.id}
                track={track}
                index={index + 1}
                project={project}
                accent={accent}
                onPlay={(selected) => onPlay(() => player.play(selected, project))}
              />
            ))}
          </div>
        )}
      </section>
    </>
  )
}
