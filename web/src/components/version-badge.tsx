import { cn } from "@/lib/utils"

/**
 * The little `v3` pill, mirroring the iOS `VersionBadge`. The `player` variant
 * sits on the dark player chrome; the default one on regular app surfaces.
 */
export function VersionBadge({
  number,
  variant = "standard",
  className,
}: {
  number: number
  variant?: "standard" | "player"
  className?: string
}) {
  return (
    <span
      aria-label={`Version ${number}`}
      className={cn(
        "shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-bold tabular-nums",
        variant === "player" ? "bg-white/15 text-white/90" : "bg-muted text-muted-foreground",
        className,
      )}
    >
      v{number}
    </span>
  )
}
