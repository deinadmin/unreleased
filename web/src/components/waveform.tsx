import { useEffect, useMemo, useRef, useState } from "react"
import { resampleBars, seededBars } from "@/lib/waveform"
import { cn } from "@/lib/utils"

/**
 * Full-width seekable waveform matching the iOS `WaveformView`: rounded bars,
 * played portion in the accent color. Driven by requestAnimationFrame reading
 * `getProgress()` so playback motion stays perfectly smooth.
 */
export function Waveform({
  trackID,
  waveform,
  getProgress,
  onSeek,
  isAnimating = false,
  barCount = 60,
  accent = "#FFD000",
  base = "rgba(255,255,255,0.35)",
  className,
}: {
  trackID: string
  waveform?: number[]
  getProgress: () => number
  onSeek?: (fraction: number) => void
  isAnimating?: boolean
  barCount?: number
  accent?: string
  base?: string
  className?: string
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const [dragging, setDragging] = useState(false)
  const drag = useRef<{ active: boolean; fraction: number }>({ active: false, fraction: 0 })

  const bars = useMemo(
    () =>
      waveform && waveform.length > 0
        ? resampleBars(waveform, barCount)
        : resampleBars(seededBars(barCount, trackID), barCount),
    [waveform, barCount, trackID],
  )

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

      const progress = drag.current.active ? drag.current.fraction : getProgress()
      const gap = 1.5
      const barWidth = (width - gap * (bars.length - 1)) / bars.length

      for (let i = 0; i < bars.length; i++) {
        const x = i * (barWidth + gap)
        const barHeight = Math.max(2, bars[i] * height)
        const y = (height - barHeight) / 2
        const fraction = i / Math.max(1, bars.length - 1)
        ctx.fillStyle = fraction <= progress ? accent : base
        ctx.beginPath()
        ctx.roundRect(x, y, barWidth, barHeight, barWidth / 2)
        ctx.fill()
      }
      if (!document.hidden && (isAnimating || drag.current.active)) scheduleDraw()
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
  }, [bars, accent, base, getProgress, isAnimating, dragging])

  const fractionFromEvent = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const rect = event.currentTarget.getBoundingClientRect()
    return Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))
  }

  return (
    <canvas
      ref={canvasRef}
      className={cn("h-11 w-full touch-none", onSeek && "cursor-default", className)}
      onPointerDown={(event) => {
        if (!onSeek) return
        event.currentTarget.setPointerCapture(event.pointerId)
        drag.current = { active: true, fraction: fractionFromEvent(event) }
        setDragging(true)
      }}
      onPointerMove={(event) => {
        if (drag.current.active) drag.current.fraction = fractionFromEvent(event)
      }}
      onPointerUp={(event) => {
        if (!drag.current.active) return
        drag.current.active = false
        setDragging(false)
        onSeek?.(fractionFromEvent(event))
      }}
      onPointerCancel={() => {
        drag.current.active = false
        setDragging(false)
      }}
    />
  )
}
