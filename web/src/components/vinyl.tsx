import { cn } from "@/lib/utils"

/** Vinyl record matching the iOS `VinylRecordView` (grooves + gradient label). */
export function Vinyl({
  labelGradient,
  spinning,
  className,
}: {
  labelGradient: string
  spinning: boolean
  className?: string
}) {
  return (
    <div
      className={cn("relative aspect-square rounded-full", className)}
      style={{
        background: "#1a1a1a",
        animation: "vinyl-spin 3.5s linear infinite",
        animationPlayState: spinning ? "running" : "paused",
      }}
    >
      {[0.88, 0.76, 0.64, 0.52].map((f) => (
        <div
          key={f}
          className="absolute rounded-full border-[0.5px] border-white/5"
          style={{
            width: `${f * 100}%`,
            height: `${f * 100}%`,
            left: `${(1 - f) * 50}%`,
            top: `${(1 - f) * 50}%`,
          }}
        />
      ))}
      <div
        className="absolute left-[35%] top-[35%] h-[30%] w-[30%] rounded-full"
        style={{ background: labelGradient }}
      />
      <div className="absolute left-[47%] top-[47%] h-[6%] w-[6%] rounded-full bg-[#262626]" />
    </div>
  )
}
