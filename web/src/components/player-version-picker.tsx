import { Plus } from "lucide-react"
import { useCallback, useEffect, useRef, useState } from "react"
import { prefersDarkForegroundOn } from "@/lib/accent-color"
import type { TrackVersion } from "@/lib/types"
import { cn } from "@/lib/utils"

const ROW_SPACING = 49
const ROW_HEIGHT = 44

interface VersionPickerProps {
  versions: TrackVersion[]
  selectedVersionID: string
  versionNumber: (version: TrackVersion) => number
  versionName: (version: TrackVersion) => string
  /** The project's accent, used to tint the selected version. */
  accent: string
  /** `wasTapped` distinguishes a direct click from a settled drag, like iOS. */
  onSelect: (version: TrackVersion, wasTapped: boolean) => void
  className?: string
}

/** Foreground treatment for whatever sits on top of the accent fill. */
function selectionTones(accent: string) {
  const dark = prefersDarkForegroundOn(accent)
  return {
    label: dark ? "text-black/90" : "text-white",
    badge: dark ? "bg-black/10 text-black/70" : "bg-white/20 text-white/85",
    ring: dark ? "ring-black/10" : "ring-white/25",
  }
}

/**
 * Pointer-friendly counterpart to the wheel: a plain list in document order,
 * every row the same size, filling whatever height the player gives it.
 */
export function PlayerVersionList({
  versions,
  selectedVersionID,
  versionNumber,
  versionName,
  accent,
  onSelect,
  onAddVersion,
  className,
}: VersionPickerProps & {
  /** Owners get an entry that opens the versions dialog. */
  onAddVersion?: () => void
}) {
  const tones = selectionTones(accent)
  return (
    <div
      role="listbox"
      aria-label="Version picker"
      className={cn(
        "flex max-h-full w-full flex-col gap-1 overflow-y-auto overscroll-contain py-1 [scrollbar-width:thin]",
        className,
      )}
    >
      {onAddVersion && (
        <button
          type="button"
          onClick={onAddVersion}
          style={{ height: ROW_HEIGHT }}
          className="flex shrink-0 items-center gap-2.5 rounded-xl px-3.5 text-left text-white/70 transition-colors hover:bg-white/10 hover:text-white"
        >
          {/* Sits in the version badge's slot so the labels line up. */}
          <span className="shrink-0 rounded-full bg-white/10 px-1.5 py-1">
            <Plus className="size-3" strokeWidth={3} />
          </span>
          <span className="min-w-0 truncate text-[14px] font-medium">Add a version</span>
        </button>
      )}

      {versions.map((version) => {
        const isSelected = version.id === selectedVersionID
        return (
          <button
            key={version.id}
            type="button"
            role="option"
            aria-selected={isSelected}
            onClick={() => onSelect(version, true)}
            className={cn(
              "flex shrink-0 items-center gap-2.5 rounded-xl px-3.5 text-left transition-colors",
              !isSelected && "text-white hover:bg-white/10",
            )}
            style={{
              height: ROW_HEIGHT,
              background: isSelected ? accent : undefined,
            }}
          >
            <span
              className={cn(
                "shrink-0 rounded-full px-1.5 py-1 text-[10px] font-bold tabular-nums",
                isSelected ? tones.badge : "bg-white/10 text-white/50",
              )}
            >
              v{versionNumber(version)}
            </span>
            <span
              className={cn(
                "min-w-0 truncate text-[14px]",
                isSelected ? cn("font-semibold", tones.label) : "font-medium",
              )}
            >
              {versionName(version)}
            </span>
          </button>
        )
      })}
    </div>
  )
}

/**
 * The vertical version wheel from the iOS player: rows scale, fade and blur
 * away from a fixed selection plate, and can be dragged, scrolled, clicked or
 * arrowed through. Committing a pick calls `onSelect` once the wheel settles.
 */
export function PlayerVersionWheel({
  versions,
  selectedVersionID,
  versionNumber,
  versionName,
  accent,
  onSelect,
  className,
}: VersionPickerProps) {
  const tones = selectionTones(accent)
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [dragStartIndex, setDragStartIndex] = useState(0)
  const [dragOffset, setDragOffset] = useState(0)
  const [isDragging, setIsDragging] = useState(false)
  const drag = useRef<{ active: boolean; startY: number; startIndex: number }>({
    active: false,
    startY: 0,
    startIndex: 0,
  })
  const wheelTimer = useRef(0)

  const clampIndex = useCallback(
    (index: number) => Math.min(Math.max(index, 0), Math.max(versions.length - 1, 0)),
    [versions.length],
  )

  // Follow the active version whenever it changes outside the wheel. Keyed on
  // the version IDs so a freshly-derived array can't reset an in-flight drag.
  const versionsKey = versions.map((version) => version.id).join(",")
  const versionsRef = useRef(versions)
  versionsRef.current = versions
  useEffect(() => {
    const index = versionsRef.current.findIndex((version) => version.id === selectedVersionID)
    setSelectedIndex(Math.max(index, 0))
    setDragStartIndex(Math.max(index, 0))
    setDragOffset(0)
  }, [selectedVersionID, versionsKey])

  const choose = (index: number) => {
    const target = clampIndex(index)
    const version = versions[target]
    if (!version) return
    setSelectedIndex(target)
    setDragStartIndex(target)
    setDragOffset(0)
    onSelect(version, true)
  }

  const rubberBand = (excess: number) =>
    (1 - 1 / (Math.abs(excess) / 42 + 1)) * 28 * (excess < 0 ? -1 : 1)

  const resist = (translation: number, startIndex: number) => {
    const maximum = startIndex * ROW_SPACING
    const minimum = -Math.max(versions.length - 1 - startIndex, 0) * ROW_SPACING
    if (translation > maximum) return maximum + rubberBand(translation - maximum)
    if (translation < minimum) return minimum + rubberBand(translation - minimum)
    return translation
  }

  const onPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    event.currentTarget.setPointerCapture(event.pointerId)
    drag.current = { active: true, startY: event.clientY, startIndex: selectedIndex }
    setDragStartIndex(selectedIndex)
    setIsDragging(true)
  }

  const onPointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!drag.current.active) return
    const translation = event.clientY - drag.current.startY
    const projected = clampIndex(Math.round(drag.current.startIndex - translation / ROW_SPACING))
    setSelectedIndex(projected)
    setDragOffset(resist(translation, drag.current.startIndex))
  }

  const endDrag = () => {
    if (!drag.current.active) return
    drag.current.active = false
    // Dropping `isDragging` re-anchors the rows on the selected index, so the
    // CSS transition performs the snap.
    setIsDragging(false)
    setDragStartIndex(selectedIndex)
    setDragOffset(0)
    const version = versions[selectedIndex]
    if (version && version.id !== selectedVersionID) onSelect(version, false)
  }

  // Trackpad / wheel scrolling settles on the row it lands on.
  const onWheel = (event: React.WheelEvent<HTMLDivElement>) => {
    if (Math.abs(event.deltaY) < 2) return
    const next = clampIndex(selectedIndex + (event.deltaY > 0 ? 1 : -1))
    if (next === selectedIndex) return
    setSelectedIndex(next)
    setDragStartIndex(next)
    window.clearTimeout(wheelTimer.current)
    wheelTimer.current = window.setTimeout(() => {
      const version = versions[next]
      if (version && version.id !== selectedVersionID) onSelect(version, false)
    }, 220)
  }

  useEffect(() => () => window.clearTimeout(wheelTimer.current), [])

  return (
    <div
      role="listbox"
      aria-label="Version picker"
      tabIndex={0}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      onWheel={onWheel}
      onKeyDown={(event) => {
        if (event.key === "ArrowDown") choose(selectedIndex + 1)
        else if (event.key === "ArrowUp") choose(selectedIndex - 1)
        else return
        event.preventDefault()
      }}
      className={cn(
        "relative flex h-50 w-full touch-none items-center justify-center overflow-hidden px-5.5 outline-none",
        className,
      )}
      style={{
        WebkitMaskImage:
          "linear-gradient(to bottom, transparent 0%, rgb(0 0 0 / 0.72) 13%, black 28%, black 72%, rgb(0 0 0 / 0.72) 87%, transparent 100%)",
        maskImage:
          "linear-gradient(to bottom, transparent 0%, rgb(0 0 0 / 0.72) 13%, black 28%, black 72%, rgb(0 0 0 / 0.72) 87%, transparent 100%)",
      }}
    >
      <div
        aria-hidden
        className={cn("pointer-events-none absolute inset-x-7.5 rounded-[11px] ring-1", tones.ring)}
        style={{
          height: ROW_HEIGHT,
          background: accent,
          boxShadow: `0 4px 16px ${accent}33`,
        }}
      />

      {versions.map((version, index) => {
        const reference = isDragging ? dragStartIndex : selectedIndex
        const position = (index - reference) * ROW_SPACING + dragOffset
        const distance = Math.abs(position / ROW_SPACING)
        const isSelected = index === selectedIndex
        return (
          <button
            key={version.id}
            type="button"
            role="option"
            aria-selected={isSelected}
            onClick={() => choose(index)}
            className="absolute inset-x-5.5 flex items-center gap-2.5 rounded-[11px] px-4.5 text-left"
            style={{
              height: ROW_HEIGHT,
              transform: `translateY(${position}px) scale(${Math.max(0.76, 1 - distance * 0.085)})`,
              opacity: Math.max(0.12, 1 - distance * 0.28),
              filter: distance > 1.65 ? `blur(${(distance - 1.65) * 0.55}px)` : undefined,
              transition: isDragging ? undefined : "transform 320ms var(--ease-snappy), opacity 320ms var(--ease-snappy)",
            }}
          >
            <span className="shrink-0 rounded-full bg-white/8 px-1.5 py-1 text-[10px] font-bold text-white/85 tabular-nums">
              v{versionNumber(version)}
            </span>
            <span className="min-w-0 truncate text-[15px] font-semibold text-white">
              {versionName(version)}
            </span>
          </button>
        )
      })}
    </div>
  )
}
