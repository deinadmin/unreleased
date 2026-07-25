import { Pause, Play } from "lucide-react"
import { Link } from "react-router-dom"
import { CoverThumbnail } from "@/components/project-cover"
import { usePlayer } from "@/player/player-provider"
import { trackCountText, type Project } from "@/lib/types"

export function ProjectCard({ project }: { project: Project }) {
  const player = usePlayer()
  const isActiveProject = player.project?.id === project.id
  const showsPause = isActiveProject && player.isPlaying
  const hasPlayableTracks = project.tracks.some((t) => t.storagePath)

  const playOrPause = (event: React.MouseEvent) => {
    event.preventDefault()
    event.stopPropagation()
    if (isActiveProject) {
      player.togglePlayPause()
      return
    }
    const first = project.tracks.find((t) => t.storagePath)
    if (first) player.play(first, project)
  }

  return (
    <Link to={`/project/${project.id}`} className="group block cursor-default select-none">
      <div className="relative aspect-square overflow-hidden rounded-2xl transition-transform duration-300 ease-out group-hover:scale-[1.015] group-active:scale-[0.98]">
        <CoverThumbnail project={project} className="h-full w-full rounded-2xl" />

        {hasPlayableTracks && (
          <button
            type="button"
            onClick={playOrPause}
            aria-label={showsPause ? "Pause" : "Play"}
            className={`absolute bottom-2.5 right-2.5 flex size-8 items-center justify-center rounded-full bg-black/25 text-white shadow-sm backdrop-blur-md transition-all duration-200 hover:bg-black/40 active:scale-90 ${
              showsPause ? "opacity-100" : "opacity-0 group-hover:opacity-100"
            }`}
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
  )
}
