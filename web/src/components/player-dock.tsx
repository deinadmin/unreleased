import { ChevronDown, ChevronsRight, NotebookPen, Pause, Play, Plus, SkipBack, SkipForward } from "lucide-react"
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react"
import { useNavigate } from "react-router-dom"
import { CoverThumbnail, ProjectCover } from "@/components/project-cover"
import { ScrollingWaveform } from "@/components/scrolling-waveform"
import { useMediaQuery } from "@/hooks/use-media-query"
import { useProjects } from "@/hooks/use-projects"
import { formatDuration, formatPlaybackTime } from "@/lib/format"
import type { Project, Track } from "@/lib/types"
import { cn, isTypingTarget } from "@/lib/utils"
import { usePlayer } from "@/player/player-provider"

type PlayerValue = ReturnType<typeof usePlayer>

/**
 * Player chrome. On large screens the maximized player lives in a right
 * sidebar (open by default, pushing content aside); on small screens it is a
 * full-screen sheet. Collapsing either reveals the floating mini pill. All
 * transitions are transform-based so the states morph seamlessly.
 */
export function PlayerDock() {
  const player = usePlayer()
  const { projects } = useProjects()
  const isDesktop = useMediaQuery("(min-width: 1024px)")
  const navigate = useNavigate()

  const hasTrack = Boolean(player.track && player.project)
  const expanded = hasTrack && player.expanded

  const getProgress = useCallback(() => {
    const total = player.audio.duration
    return Number.isFinite(total) && total > 0 ? player.audio.currentTime / total : 0
  }, [player.audio])

  // Shift the page content while the sidebar player is open on big screens.
  useEffect(() => {
    document.body.classList.toggle("player-sidebar-open", expanded && isDesktop)
    return () => document.body.classList.remove("player-sidebar-open")
  }, [expanded, isDesktop])

  // Close the maximized player with Escape — unless a modal layer (dialog,
  // context menu) is open, in which case that layer consumes the press and
  // the next one closes the player.
  useEffect(() => {
    if (!expanded) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return
      const modalOpen = document.querySelector(
        '[data-slot="dialog-content"][data-state="open"], [role="menu"]',
      )
      if (modalOpen) return
      player.setExpanded(false)
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [expanded, player])

  // Space toggles playback anywhere on the page, except while typing or when
  // an interactive element is focused (Space already activates those).
  const hasTrackRef = useRef(hasTrack)
  hasTrackRef.current = hasTrack
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.code !== "Space" || event.repeat || event.defaultPrevented) return
      if (event.metaKey || event.ctrlKey || event.altKey) return
      if (!hasTrackRef.current || isTypingTarget(event.target)) return
      const target = event.target instanceof HTMLElement ? event.target : null
      if (target?.closest("button, a, [role='button'], [role='menuitem']")) return
      event.preventDefault()
      player.togglePlayPause()
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [player])

  if (!player.track || !player.project) return null

  // Prefer live store metadata (title, cover, waveform) over the play-time snapshot.
  const project = projects.find((p) => p.id === player.project!.id) ?? player.project
  const track = project.tracks.find((t) => t.id === player.track!.id) ?? player.track

  // Notes are only editable on the user's own projects; shared projects in
  // the library open the same page read-only.
  const canEditNotes = !project.ownerID
  const inLibrary = projects.some((p) => p.id === project.id)
  const openNotes = inLibrary
    ? () => {
        // The notes page is a route on the main screen, so collapse the
        // full-screen player on small devices first.
        if (!isDesktop) player.setExpanded(false)
        navigate(`/project/${project.id}/notes/${track.id}`)
      }
    : undefined

  return (
    <>
      {isDesktop ? (
        <SidebarPlayer
          player={player}
          project={project}
          track={track}
          expanded={expanded}
          onOpenNotes={openNotes}
          canEditNotes={canEditNotes}
        />
      ) : (
        <FullscreenPlayer
          player={player}
          project={project}
          track={track}
          expanded={expanded}
          onOpenNotes={openNotes}
          canEditNotes={canEditNotes}
        />
      )}

      {/* ── Mini player pill ────────────────────────────────────────────── */}
      <div
        className={cn(
          "fixed bottom-4 left-1/2 z-40 w-[min(92vw,480px)] -translate-x-1/2 transition-all duration-300 ease-snappy",
          expanded && "pointer-events-none translate-y-24 opacity-0",
        )}
        inert={expanded || undefined}
      >
        <div className="rise-in flex h-14 items-center gap-3 rounded-full bg-player-surface pl-1.5 pr-4 text-white shadow-[0_10px_30px_rgba(0,0,0,0.35)]">
          <button
            type="button"
            aria-label={player.isPlaying ? "Pause" : "Play"}
            onClick={player.togglePlayPause}
            className="relative shrink-0 overflow-hidden rounded-full transition active:scale-90"
          >
            <CoverThumbnail project={project} className="size-11 rounded-full blur-[3px]" />
            <span className="absolute inset-0 flex items-center justify-center bg-black/30 text-white">
              {player.isPlaying ? (
                <Pause className="size-4.5 fill-current" strokeWidth={0} />
              ) : (
                <Play className="ml-0.5 size-4.5 fill-current" strokeWidth={0} />
              )}
            </span>
          </button>

          <button
            type="button"
            aria-label="Maximize player"
            onClick={() => player.setExpanded(true)}
            className="flex min-w-0 flex-1 flex-col items-start gap-px text-left"
          >
            <span className="w-full truncate text-[13px] font-semibold">{track.title}</span>
            <span className="w-full truncate text-[11px] text-white/55">{project.name}</span>
          </button>

          <ScrollingWaveform
            trackID={track.id}
            waveform={track.waveform}
            getProgress={getProgress}
            onSeek={player.seek}
            duration={player.duration || track.duration}
            className="w-[130px] shrink-0"
          />
        </div>
      </div>
    </>
  )
}

/**
 * White seek bar for the maximized players: rAF-driven fill, drag to scrub,
 * and a floating timestamp tooltip that follows the pointer on hover.
 */
function ProgressSection({ player, track }: { player: PlayerValue; track: Track }) {
  const trackDuration = player.duration || track.duration
  const currentSeconds = player.progress * trackDuration
  const fillRef = useRef<HTMLDivElement>(null)
  const [hoverFraction, setHoverFraction] = useState<number | null>(null)
  const drag = useRef<{ active: boolean; fraction: number; holdUntil: number }>({
    active: false,
    fraction: 0,
    holdUntil: 0,
  })

  useEffect(() => {
    let frame = 0
    const tick = () => {
      const scrubbing = drag.current.active || performance.now() < drag.current.holdUntil
      const total = player.audio.duration
      const progress = scrubbing
        ? drag.current.fraction
        : Number.isFinite(total) && total > 0
          ? player.audio.currentTime / total
          : 0
      if (fillRef.current) {
        fillRef.current.style.width = `${Math.min(1, Math.max(0, progress)) * 100}%`
      }
      frame = requestAnimationFrame(tick)
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
  }, [player.audio])

  const fractionFromEvent = (event: React.PointerEvent<HTMLDivElement>) => {
    const rect = event.currentTarget.getBoundingClientRect()
    return Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))
  }

  return (
    <div>
      <div className="relative">
        {hoverFraction !== null && (
          <div
            className="pointer-events-none absolute -top-8 z-10 -translate-x-1/2 rounded-md bg-white px-2 py-1 text-[11px] font-semibold tabular-nums text-black shadow-lg"
            style={{ left: `${Math.min(94, Math.max(6, hoverFraction * 100))}%` }}
          >
            {formatPlaybackTime(hoverFraction * trackDuration)}
          </div>
        )}
        <div
          className="group flex h-6 cursor-default touch-none items-center"
          onPointerDown={(event) => {
            event.currentTarget.setPointerCapture(event.pointerId)
            const fraction = fractionFromEvent(event)
            drag.current = { active: true, fraction, holdUntil: 0 }
            setHoverFraction(fraction)
          }}
          onPointerMove={(event) => {
            const fraction = fractionFromEvent(event)
            if (drag.current.active) drag.current.fraction = fraction
            if (drag.current.active || event.pointerType === "mouse") setHoverFraction(fraction)
          }}
          onPointerUp={(event) => {
            if (drag.current.active) {
              drag.current.active = false
              drag.current.holdUntil = performance.now() + 300
              player.seek(fractionFromEvent(event))
            }
            if (event.pointerType !== "mouse") setHoverFraction(null)
          }}
          onPointerLeave={() => setHoverFraction(null)}
          onPointerCancel={() => {
            drag.current.active = false
            setHoverFraction(null)
          }}
        >
          <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/15 transition-[height] duration-150 ease-snappy group-hover:h-2.5">
            <div ref={fillRef} className="h-full rounded-full bg-white" />
          </div>
        </div>
      </div>
      <div className="flex justify-between text-[11px] tabular-nums text-white/45">
        <span>{formatPlaybackTime(currentSeconds)}</span>
        <span>{formatDuration(trackDuration)}</span>
      </div>
    </div>
  )
}

/**
 * Bottom-aligned preview of the track's notes: an 8-line window that scrolls
 * for longer notes, fading out at the bottom while more content is below.
 * Clicking it opens the notes page when `onOpen` is provided (the editor for
 * own projects, the read-only view for shared ones).
 */
function NotesPreview({
  notes,
  onOpen,
  editable,
  className,
}: {
  notes: string
  onOpen?: () => void
  editable?: boolean
  className?: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const [faded, setFaded] = useState(false)

  const updateFade = useCallback(() => {
    const el = ref.current
    if (el) setFaded(el.scrollTop + el.clientHeight < el.scrollHeight - 1)
  }, [])

  useLayoutEffect(() => {
    updateFade()
  }, [notes, updateFade])

  if (!notes.trim()) return null
  return (
    <div
      ref={ref}
      role={onOpen ? "button" : undefined}
      tabIndex={onOpen ? 0 : undefined}
      aria-label={onOpen ? (editable ? "Edit notes" : "View notes") : undefined}
      onClick={onOpen}
      onKeyDown={
        onOpen
          ? (event) => {
              if (event.key === "Enter") onOpen()
            }
          : undefined
      }
      onScroll={updateFade}
      className={cn(
        "max-h-40 overflow-y-auto overscroll-contain whitespace-pre-wrap text-[13px] leading-5 text-white/60 [scrollbar-width:thin]",
        onOpen && "cursor-default outline-none transition-colors hover:text-white/85 focus:outline-none focus:ring-0",
        className,
      )}
      style={{
        // The mask is always applied; only the registered --notes-fade-alpha
        // custom property animates, fading the bottom fade in and out.
        "--notes-fade-alpha": faded ? 0 : 1,
        WebkitMaskImage:
          "linear-gradient(to bottom, black 45%, rgb(0 0 0 / var(--notes-fade-alpha)) 100%)",
        maskImage:
          "linear-gradient(to bottom, black 45%, rgb(0 0 0 / var(--notes-fade-alpha)) 100%)",
        transition: "--notes-fade-alpha 300ms var(--ease-snappy)",
      } as React.CSSProperties}
    >
      {notes}
    </div>
  )
}

/** Previous / play-pause / next transport row, with an optional notes toggle. */
function TransportControls({
  player,
  notesVisible,
  onToggleNotes,
}: {
  player: PlayerValue
  notesVisible?: boolean
  onToggleNotes?: () => void
}) {
  return (
    <div className="flex items-center justify-center gap-8">
      {onToggleNotes && (
        <button
          type="button"
          aria-label={notesVisible ? "Hide notes" : "Show notes"}
          aria-pressed={notesVisible}
          onClick={onToggleNotes}
          className={cn(
            "transition active:scale-90",
            notesVisible ? "text-white" : "text-white/40 hover:text-white/70",
          )}
        >
          <NotebookPen className="size-5" />
        </button>
      )}
      <button
        type="button"
        aria-label="Previous track"
        onClick={player.previous}
        className="text-white/70 transition hover:text-white active:scale-90"
      >
        <SkipBack className="size-7 fill-current" strokeWidth={0} />
      </button>
      <button
        type="button"
        aria-label={player.isPlaying ? "Pause" : "Play"}
        onClick={player.togglePlayPause}
        className="flex size-16 items-center justify-center rounded-full bg-white text-black shadow-lg transition active:scale-95"
      >
        {player.isPlaying ? (
          <Pause className="size-6 fill-current" strokeWidth={0} />
        ) : (
          <Play className="ml-1 size-6 fill-current" strokeWidth={0} />
        )}
      </button>
      <button
        type="button"
        aria-label="Next track"
        onClick={player.next}
        className="text-white/70 transition hover:text-white active:scale-90"
      >
        <SkipForward className="size-7 fill-current" strokeWidth={0} />
      </button>
      {onToggleNotes && <span aria-hidden className="size-5 opacity-0" />}
    </div>
  )
}

/** Collapsible wrapper that smoothly animates the notes preview in and out. */
function CollapsibleNotes({
  visible,
  notes,
  onOpen,
  canEdit,
  notesClassName,
}: {
  visible: boolean
  notes: string
  onOpen?: () => void
  canEdit?: boolean
  notesClassName?: string
}) {
  return (
    <div
      className={cn(
        "grid shrink-0 transition-[grid-template-rows] duration-300 ease-snappy",
        visible ? "grid-rows-[1fr]" : "grid-rows-[0fr]",
      )}
    >
      <div
        className={cn(
          "min-h-0 overflow-hidden transition-opacity duration-300 ease-snappy",
          visible ? "opacity-100" : "opacity-0",
        )}
        inert={!visible || undefined}
      >
        {notes.trim() ? (
          <NotesPreview
            notes={notes}
            onOpen={onOpen}
            editable={canEdit}
            className={cn("mt-6", notesClassName)}
          />
        ) : canEdit && onOpen ? (
          <button
            type="button"
            onClick={onOpen}
            className="mt-6 flex w-full items-center justify-center gap-1.5 rounded-full bg-white/10 px-3.5 py-2 text-[12px] font-semibold text-white/55 transition hover:bg-white/15 hover:text-white/85 active:scale-95"
          >
            <Plus className="size-3.5" strokeWidth={2.5} />
            Add notes
          </button>
        ) : null}
      </div>
    </div>
  )
}

/** Big screens: maximized player docked as a right sidebar. */
function SidebarPlayer({
  player,
  project,
  track,
  expanded,
  onOpenNotes,
  canEditNotes,
}: {
  player: PlayerValue
  project: Project
  track: Track
  expanded: boolean
  onOpenNotes?: () => void
  canEditNotes?: boolean
}) {
  const [showNotes, setShowNotes] = useState(true)
  const canToggleNotes = Boolean(canEditNotes) || track.notes.trim().length > 0
  return (
    <aside
      aria-label="Now playing"
      inert={!expanded || undefined}
      className={cn(
        "fixed inset-y-0 right-0 z-50 flex w-(--player-sidebar-width) flex-col border-l border-white/8 bg-[#161616] text-white transition-transform duration-400 ease-snappy",
        expanded ? "translate-x-0" : "translate-x-full",
      )}
    >
      {/* Header row matches the app menubar height (h-14) so its content
          shares the same vertical centerline. */}
      <div className="flex h-14 shrink-0 items-center justify-between border-b border-white/8 pl-5 pr-3">
        <span className="text-[11px] font-semibold uppercase tracking-[0.14em] text-white/40">
          Now playing
        </span>
        <button
          type="button"
          aria-label="Minimize player"
          onClick={() => player.setExpanded(false)}
          className="flex size-9 items-center justify-center rounded-full text-white/45 transition-colors hover:bg-white/10 hover:text-white/80"
        >
          <ChevronsRight className="size-5" />
        </button>
      </div>

      <div className="flex min-h-0 flex-1 flex-col px-8">
        {/* Like the fullscreen player, the cover fills the room left over
            after the notes take their natural height, shrinking only when
            the sidebar is too short to fit everything at full size. */}
        <div className="flex min-h-0 flex-1 items-center justify-center">
          <div
            className="aspect-square"
            style={{ height: "min(100%, calc(0.72 * (var(--player-sidebar-width) - 4rem)))" }}
          >
            <ProjectCover project={project} isPlaying={player.isPlaying} showVinyl={false} className="h-full w-full" />
          </div>
        </div>
        <div className="mt-7 flex shrink-0 flex-col items-center gap-1">
          <span className="max-w-full truncate text-lg font-bold">{track.title}</span>
          <span className="max-w-full truncate text-[13px] text-white/55">{project.name}</span>
        </div>
        <CollapsibleNotes
          visible={showNotes}
          notes={track.notes}
          onOpen={onOpenNotes}
          canEdit={canEditNotes}
        />
      </div>

      <div className="px-8 pb-10 pt-4">
        <ProgressSection player={player} track={track} />
        <div className="mt-4">
          <TransportControls
            player={player}
            notesVisible={showNotes}
            onToggleNotes={canToggleNotes ? () => setShowNotes((v) => !v) : undefined}
          />
        </div>
      </div>
    </aside>
  )
}

/** Small screens: maximized player as a full-screen sheet. */
function FullscreenPlayer({
  player,
  project,
  track,
  expanded,
  onOpenNotes,
  canEditNotes,
}: {
  player: PlayerValue
  project: Project
  track: Track
  expanded: boolean
  onOpenNotes?: () => void
  canEditNotes?: boolean
}) {
  const [showNotes, setShowNotes] = useState(true)
  const canToggleNotes = Boolean(canEditNotes) || track.notes.trim().length > 0
  return (
    <div
      aria-label="Now playing"
      inert={!expanded || undefined}
      className={cn(
        "fixed inset-0 z-50 flex flex-col bg-[#161616] px-8 pb-[max(2.5rem,env(safe-area-inset-bottom))] pt-[max(0.75rem,env(safe-area-inset-top))] text-white transition-transform duration-400 ease-snappy",
        expanded ? "translate-y-0" : "translate-y-full",
      )}
    >
      <button
        type="button"
        aria-label="Minimize player"
        onClick={() => player.setExpanded(false)}
        className="mx-auto flex size-10 items-center justify-center rounded-full text-white/45 transition-colors hover:text-white/80"
      >
        <ChevronDown className="size-6" />
      </button>

      <div className="flex min-h-0 flex-1 flex-col">
        {/* The cover fills the room left over after the notes (capped at six
            lines here) take their natural height, so it only shrinks on
            screens that are too small to fit everything at full size. */}
        <div className="flex min-h-0 flex-1 items-center justify-center">
          <div
            className="aspect-square"
            style={{ height: "min(100%, calc(0.74 * (100vw - 4rem)), 20rem)" }}
          >
            <ProjectCover project={project} isPlaying={player.isPlaying} showVinyl={false} className="h-full w-full" />
          </div>
        </div>
        <div className="mt-8 flex shrink-0 flex-col items-center gap-1">
          <span className="max-w-full truncate text-xl font-bold">{track.title}</span>
          <span className="max-w-full truncate text-[13px] text-white/55">{project.name}</span>
        </div>
        <CollapsibleNotes
          visible={showNotes}
          notes={track.notes}
          onOpen={onOpenNotes}
          canEdit={canEditNotes}
          notesClassName="max-h-30"
        />
      </div>

      <div className="mt-4">
        <ProgressSection player={player} track={track} />
      </div>
      <div className="mt-5">
        <TransportControls
          player={player}
          notesVisible={showNotes}
          onToggleNotes={canToggleNotes ? () => setShowNotes((v) => !v) : undefined}
        />
      </div>
    </div>
  )
}
