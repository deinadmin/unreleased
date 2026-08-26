import { cn } from "@/lib/utils"

/**
 * Rotating ring with one emphasized half and one muted half, mirroring the iOS
 * `TwoToneCircleSpinner`. Both halves are drawn in `currentColor`, so callers
 * only set a text color and a size.
 */
export function TwoToneCircleSpinner({
  className,
  strokeWidth = 2.5,
  style,
}: {
  className?: string
  strokeWidth?: number
  style?: React.CSSProperties
}) {
  // Half of the circumference of the r=10 path, so the emphasized arc covers
  // exactly one half of the ring.
  const halfCircumference = Math.PI * 10

  return (
    <svg
      aria-hidden
      viewBox="0 0 24 24"
      fill="none"
      className={cn("animate-spin", className)}
      style={style}
    >
      <circle
        cx="12"
        cy="12"
        r="10"
        stroke="currentColor"
        strokeOpacity={0.25}
        strokeWidth={strokeWidth}
      />
      <circle
        cx="12"
        cy="12"
        r="10"
        stroke="currentColor"
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        strokeDasharray={`${halfCircumference} ${halfCircumference}`}
      />
    </svg>
  )
}
