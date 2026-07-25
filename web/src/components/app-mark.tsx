import { cn } from "@/lib/utils"

/** The app icon, rendered like the iOS `AuthAppMark`. */
export function AppMark({ className, alt = "unreleased app icon" }: { className?: string; alt?: string }) {
  return (
    <img
      src="/app-icon.png"
      alt={alt}
      draggable={false}
      className={cn("select-none rounded-[25%] shadow-[0_6px_12px_rgba(0,0,0,0.16)]", className)}
    />
  )
}
