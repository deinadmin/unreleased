import { useStorageUrl } from "@/hooks/use-storage-url"
import { gradientCSS, vinylGradientCSS, type Project } from "@/lib/types"
import { cn } from "@/lib/utils"
import { Vinyl } from "./vinyl"

/**
 * Animated cover square matching the iOS `ProjectCoverView`:
 * paused → cover centered, vinyl hidden behind it;
 * playing → cover slides left, vinyl slides out right and spins.
 */
export function ProjectCover({
  project,
  isPlaying,
  showVinyl = true,
  className,
}: {
  project: Project
  isPlaying: boolean
  /** Set false to render just the cover square without the sliding vinyl. */
  showVinyl?: boolean
  className?: string
}) {
  const coverUrl = useStorageUrl(project.coverStoragePath)

  return (
    <div className={cn("relative aspect-square", className)}>
      {showVinyl && (
        <div
          className="absolute inset-[12.5%] transition-transform duration-500 ease-in-out"
          style={{ transform: isPlaying ? "translateX(41.67%)" : "translateX(0)" }}
        >
          <Vinyl labelGradient={vinylGradientCSS(project)} spinning={isPlaying} className="h-full w-full" />
        </div>
      )}

      <div
        className="absolute inset-0 overflow-hidden rounded-[7.7%] shadow-[0_8px_20px_rgba(0,0,0,0.2)] transition-transform duration-500 ease-in-out"
        style={{
          transform: showVinyl && isPlaying ? "translateX(-18.75%)" : "translateX(0)",
          background: coverUrl ? "#1f1f1f" : gradientCSS(project.gradient),
        }}
      >
        {coverUrl && (
          <img
            src={coverUrl}
            alt={project.name}
            draggable={false}
            className="h-full w-full select-none object-cover"
          />
        )}
      </div>
    </div>
  )
}

/** Small static cover thumbnail (lists / mini player). */
export function CoverThumbnail({ project, className }: { project: Project; className?: string }) {
  const coverUrl = useStorageUrl(project.coverStoragePath)
  return (
    <div
      className={cn("overflow-hidden rounded-xl", className)}
      style={{ background: coverUrl ? "#1f1f1f" : gradientCSS(project.gradient) }}
    >
      {coverUrl && (
        <img
          src={coverUrl}
          alt={project.name}
          draggable={false}
          className="h-full w-full select-none object-cover"
        />
      )}
    </div>
  )
}
