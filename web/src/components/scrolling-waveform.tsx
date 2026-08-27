import { useEffect, useMemo, useRef, useState } from "react"
import { formatDuration, formatPlaybackTime } from "@/lib/format"
import { seededBars } from "@/lib/waveform"
import { cn } from "@/lib/utils"

/**
 * Zoomed-in sliding waveform window matching the iOS `ScrollingMiniWaveformView`:
 * the playhead stays pinned to the center marker while the waveform scrolls
 * right-to-left during playback. Dragging scrubs (drag right = rewind).
 * When `duration` is provided, a floating "current/total" tooltip appears on
 * hover and stays visible while dragging.
 */
export function ScrollingWaveform({
  trackID,
  waveform,
  getProgress,
  onSeek,
  duration,
  isAnimating = false,
  visibleBars = 38,
  barColor = "rgba(255,255,255,0.72)",
  playedColor = "rgba(255,255,255,1)",
  playheadColor = "#FFD000",
  className,
}: {
  trackID: string
  waveform?: number[]
  getProgress: () => number
  onSeek?: (fraction: number) => void
  /** Track duration in seconds — enables the scrub-time tooltip. */
  duration?: number
  /** True only while this waveform's audio is actively advancing. */
  isAnimating?: boolean
  visibleBars?: number
  barColor?: string
  playedColor?: string
  playheadColor?: string
  className?: string
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const tooltipTextRef = useRef<HTMLSpanElement>(null)
  const [hovering, setHovering] = useState(false)
  const [dragging, setDragging] = useState(false)
  const [isVisible, setIsVisible] = useState(true)
  const drag = useRef<{
    active: boolean
    startX: number
    startFraction: number
    fraction: number
    /** Time playback position is held after a seek so the audio can catch up. */
    holdUntil: number
  }>({ active: false, startX: 0, startFraction: 0, fraction: 0, holdUntil: 0 })

  const bars = useMemo(
    () => (waveform && waveform.length > 0 ? waveform : seededBars(200, trackID)),
    [waveform, trackID],
  )

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas || typeof IntersectionObserver === "undefined") return
    const observer = new IntersectionObserver(
      ([entry]) => setIsVisible(entry.isIntersecting),
      { rootMargin: "80px" },
    )
    observer.observe(canvas)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext("2d")
    if (!ctx) return
    let frame = 0

    const scheduleDraw = () => {
      if (!frame) frame = requestAnimationFrame(draw)
    }

    const draw = () => {
      frame = 0
      const dpr = window.devicePixelRatio || 1
      const width = canvas.clientWidth
      const height = canvas.clientHeight
      if (canvas.width !== width * dpr || canvas.height !== height * dpr) {
        canvas.width = width * dpr
        canvas.height = height * dpr
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, width, height)

      const scrubbing = drag.current.active || performance.now() < drag.current.holdUntil
      const progress = Math.min(1, Math.max(0, scrubbing ? drag.current.fraction : getProgress()))

      if (tooltipTextRef.current && duration) {
        tooltipTextRef.current.textContent = `${formatPlaybackTime(progress * duration)}/${formatDuration(duration)}`
      }

      const step = width / visibleBars
      const barWidth = Math.max(1.5, step - 2)
      const centerX = width / 2
      const currentBar = progress * (bars.length - 1)

      for (let i = 0; i < bars.length; i++) {
        const x = centerX + (i - currentBar) * step - barWidth / 2
        if (x + barWidth < 0 || x > width) continue
        const barHeight = Math.max(2, bars[i] * height)
        const y = (height - barHeight) / 2
        // Fade bars toward the edges of the window.
        const edgeDistance = Math.min(x + barWidth / 2, width - (x + barWidth / 2)) / (width / 2)
        ctx.globalAlpha = Math.max(0.12, Math.min(1, edgeDistance * 2.4))
        ctx.fillStyle = i <= currentBar ? playedColor : barColor
        ctx.beginPath()
        ctx.roundRect(x, y, barWidth, barHeight, barWidth / 2)
        ctx.fill()
      }
      ctx.globalAlpha = 1

      // Center playhead marker.
      ctx.fillStyle = playheadColor
      ctx.beginPath()
      ctx.roundRect(centerX - 1, 1, 2, height - 2, 1)
      ctx.fill()

      const shouldContinue =
        isVisible &&
        !document.hidden &&
        (isAnimating || drag.current.active || performance.now() < drag.current.holdUntil)
      if (shouldContinue) scheduleDraw()
    }
    const resizeObserver = new ResizeObserver(scheduleDraw)
    resizeObserver.observe(canvas)
    document.addEventListener("visibilitychange", scheduleDraw)
    scheduleDraw()
    return () => {
      cancelAnimationFrame(frame)
      resizeObserver.disconnect()
      document.removeEventListener("visibilitychange", scheduleDraw)
    }
  }, [
    bars,
    visibleBars,
    barColor,
    playedColor,
    playheadColor,
    getProgress,
    duration,
    dragging,
    hovering,
    isAnimating,
    isVisible,
  ])

  const tooltipVisible = Boolean(duration) && (dragging || hovering)

  return (
    <div className={cn("relative h-9", className)}>
      {duration !== undefined && (
        <div
          className={cn(
            "pointer-events-none absolute bottom-[calc(100%+20px)] left-1/2 z-10 -translate-x-1/2 rounded-lg bg-player-surface px-2.5 py-1.5 text-[11px] font-semibold tabular-nums text-white shadow-[0_10px_30px_rgba(0,0,0,0.35)] transition-all duration-200 ease-snappy",
            tooltipVisible ? "translate-y-0 scale-100 opacity-100" : "translate-y-1.5 scale-90 opacity-0",
          )}
        >
          <span ref={tooltipTextRef} />
        </div>
      )}
      <canvas
        ref={canvasRef}
        className="h-full w-full cursor-grab touch-none active:cursor-grabbing"
        onPointerEnter={(event) => {
          if (event.pointerType === "mouse") setHovering(true)
        }}
        onPointerLeave={() => setHovering(false)}
        onPointerDown={(event) => {
          if (!onSeek) return
          event.currentTarget.setPointerCapture(event.pointerId)
          const fraction = getProgress()
          drag.current = {
            active: true,
            startX: event.clientX,
            startFraction: fraction,
            fraction,
            holdUntil: 0,
          }
          setDragging(true)
        }}
        onPointerMove={(event) => {
          const state = drag.current
          if (!state.active) return
          const width = event.currentTarget.clientWidth
          const step = width / visibleBars
          const deltaBars = (event.clientX - state.startX) / step
          state.fraction = Math.min(
            1,
            Math.max(0, state.startFraction - deltaBars / Math.max(1, bars.length - 1)),
          )
        }}
        onPointerUp={() => {
          const state = drag.current
          setDragging(false)
          if (!state.active) return
          state.active = false
          state.holdUntil = performance.now() + 300
          onSeek?.(state.fraction)
        }}
        onPointerCancel={() => {
          drag.current.active = false
          setDragging(false)
        }}
      />
    </div>
  )
}
