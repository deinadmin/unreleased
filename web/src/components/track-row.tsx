import { MoreHorizontal } from "lucide-react"
import { useState } from "react"
import { useContextMenu } from "@/components/context-menu"
import { PlayingBars } from "@/components/playing-bars"
import { TwoToneCircleSpinner } from "@/components/two-tone-spinner"
import { useTrackActions } from "@/components/track-actions"
import { VersionBadge } from "@/components/version-badge"
import { cn } from "@/lib/utils"
import { formatDuration, formatFileSize, formatRelativeDate } from "@/lib/format"
import type { Project, Track } from "@/lib/types"
import { activeVersionNumber, hasMultipleVersions } from "@/lib/versions"
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
  const contextMenu = useContextMenu()
  const [contextMenuOpen, setContextMenuOpen] = useState(false)
  const { menuItems, dialogs } = useTrackActions({ track, project, onPlay })
  const isActive = player.track?.id === track.id && player.project?.id === project.id
  const versionNumber = hasMultipleVersions(track) ? activeVersionNumber(track) : null

  const play = () => (onPlay ? onPlay(track) : player.play(track, project))

  const openContextMenu = (event: React.MouseEvent) => {
    contextMenu.open(event, menuItems(), { onClose: () => setContextMenuOpen(false) })
    setContextMenuOpen(true)
  }

  const openMobileMenu = (event: React.MouseEvent<HTMLButtonElement>) => {
    event.stopPropagation()
    const rect = event.currentTarget.getBoundingClientRect()
    contextMenu.openAt(rect.left, rect.bottom + 4, menuItems(), {
      onClose: () => setContextMenuOpen(false),
    })
    setContextMenuOpen(true)
  }

  return (
    <>
      <div
        onContextMenu={openContextMenu}
        className={cn(
          "track-row group relative flex w-full items-center overflow-hidden rounded-xl transition-colors hover:bg-muted/60",
          contextMenuOpen && "track-row-menu-open bg-muted/60",
        )}
      >
        <button
          type="button"
          onClick={play}
          disabled={!track.storagePath}
          className="flex min-w-0 flex-1 items-center gap-3 rounded-xl px-3 py-3 text-left disabled:cursor-default disabled:opacity-50"
        >
          <span className="flex w-7 shrink-0 items-center justify-center">
            {isActive && player.isLoading ? (
              <TwoToneCircleSpinner className="size-4" style={{ color: accent }} />
            ) : isActive && player.isPlaying ? (
              <PlayingBars color={accent} />
            ) : (
              <span className="text-sm font-medium tabular-nums text-muted-foreground">
                {index}
              </span>
            )}
          </span>

          <span className="track-row-copy flex min-w-0 flex-1 flex-col gap-0.5">
            <span className="flex min-w-0 items-center gap-1.5">
              <span
                className="min-w-0 truncate text-[15px] font-semibold"
                style={isActive ? { color: accent } : undefined}
              >
                {track.title}
              </span>
              {versionNumber !== null && <VersionBadge number={versionNumber} />}
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
          aria-expanded={contextMenuOpen}
          onClick={openMobileMenu}
          className="track-row-action absolute right-2.5 flex size-10 shrink-0 items-center justify-center rounded-full text-muted-foreground hover:bg-muted hover:text-foreground"
        >
          <MoreHorizontal className="size-5" />
        </button>
      </div>

      {dialogs}
    </>
  )
}
