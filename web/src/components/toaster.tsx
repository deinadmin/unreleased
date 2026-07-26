import { AlertCircle, CheckCircle2, Info, X } from "lucide-react"
import { useSyncExternalStore, type ReactNode } from "react"
import {
  dismissToast,
  getToasts,
  pauseToasts,
  resumeToasts,
  subscribeToasts,
  type ToastItem,
} from "@/lib/toast"
import { cn } from "@/lib/utils"
import { usePlayer } from "@/player/player-provider"

/**
 * Bottom-left toast stack. `children` is pinned to the bottom of the stack and
 * is where the upload progress card lives, so progress stays put while
 * transient toasts come and go above it.
 */
export function Toaster({ children }: { children?: ReactNode }) {
  const toasts = useSyncExternalStore(subscribeToasts, getToasts)
  const player = usePlayer()
  // The mini player pill owns the bottom-left corner whenever a track is loaded
  // and the maximized player is closed; otherwise the stack sits in the corner.
  const miniPlayerVisible = Boolean(player.track) && !player.expanded

  return (
    <div
      aria-live="polite"
      onPointerEnter={pauseToasts}
      onPointerLeave={resumeToasts}
      className="pointer-events-none fixed left-4 z-40 flex w-72 max-w-[calc(100vw-2rem)] flex-col-reverse transition-[bottom] duration-300 ease-snappy"
      style={{ bottom: miniPlayerVisible ? "6rem" : "1rem" }}
    >
      {children}
      {toasts.map((item) => (
        <ToastRow key={item.id} item={item} />
      ))}
    </div>
  )
}

function ToastRow({ item }: { item: ToastItem }) {
  return (
    // Collapsing the row on the way out closes the gap it leaves behind, so
    // the toasts above settle down instead of jumping.
    <div
      className={cn(
        "grid transition-[grid-template-rows] duration-200 ease-snappy",
        item.exiting ? "grid-rows-[0fr]" : "grid-rows-[1fr]",
      )}
    >
      <div className="min-h-0 overflow-hidden">
        {/* Padding rather than a margin, so the spacing collapses too. */}
        <div className="pb-2">
          <div
            role="status"
            className={cn(
              "group pointer-events-auto flex gap-2.5 rounded-2xl border border-border/60 bg-background/95 p-3 shadow-xl backdrop-blur-xl",
              // `scale-*` drives the `scale` property in Tailwind v4, not `transform`.
              "transition-[opacity,scale] duration-200 ease-snappy",
              // A title on its own sits centered against the icon; once there is
              // a description the row aligns to the top instead.
              item.description ? "items-start" : "items-center",
              item.exiting
                ? "scale-95 opacity-0"
                : "animate-in fade-in-0 zoom-in-95 slide-in-from-bottom-2",
            )}
          >
            <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-secondary">
              <ToastIcon variant={item.variant} />
            </span>

            <span
              className={cn(
                "flex min-w-0 flex-1 flex-col gap-0.5",
                item.description && "pt-0.5",
              )}
            >
              <span className="text-[13px] leading-snug font-medium">{item.title}</span>
              {item.description && (
                <span className="text-[11px] leading-snug text-muted-foreground">
                  {item.description}
                </span>
              )}
            </span>

            <button
              type="button"
              aria-label="Dismiss"
              onClick={() => dismissToast(item.id)}
              className={cn(
                "-mr-0.5 flex size-6 shrink-0 items-center justify-center rounded-full text-muted-foreground opacity-0 transition-opacity duration-150 hover:bg-muted hover:text-foreground focus-visible:opacity-100 group-hover:opacity-100",
                item.description && "-mt-0.5",
              )}
            >
              <X className="size-3.5" />
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

function ToastIcon({ variant }: { variant: ToastItem["variant"] }) {
  if (variant === "success") {
    return <CheckCircle2 className="size-3.5 text-green-600 dark:text-green-500" />
  }
  if (variant === "error") return <AlertCircle className="size-3.5 text-destructive" />
  return <Info className="size-3.5 text-muted-foreground" />
}
