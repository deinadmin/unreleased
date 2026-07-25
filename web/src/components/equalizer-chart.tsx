import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react"
import { EQUALIZER_BANDS, GAIN_STEP, MAX_GAIN, formatGain } from "@/player/equalizer"

/**
 * Web port of the iOS `InteractiveEqualizerChart`: a smoothed curve through the
 * seven band gains that is dragged directly, with the grid and curve bleeding
 * past the content gutter the way the iOS chart bleeds to the screen edges.
 */

const HEIGHT = 300
const TOP_INSET = 34
const BOTTOM_INSET = 48
/**
 * The iOS 30pt gap between the outer bands and the chart edge. Everything the
 * chart bleeds past the text column is added on top, so the plot itself always
 * measures `column − 60`, no matter how much runway the fade gets.
 */
const BASE_PLOT_INSET = 30
const PLOT_HEIGHT = HEIGHT - TOP_INSET - BOTTOM_INSET
const PLOT_BOTTOM = TOP_INSET + PLOT_HEIGHT
const MID_Y = TOP_INSET + PLOT_HEIGHT / 2
/** ±12 dB reaches 46% of the plot height, leaving headroom above and below. */
const GAIN_SPAN = PLOT_HEIGHT * 0.46
const LAST_BAND = EQUALIZER_BANDS.length - 1
const CURVE_DURATION = 320
/** Steps in the smoothstep alpha ramp applied at the left and right edges. */
const EDGE_FADE_STEPS = 12
/** Pointer distance from a handle that counts as hovering it. */
const HOVER_RADIUS = 18

interface Point {
  x: number
  y: number
}

export function EqualizerChart({
  gains,
  enabled,
  onGainChange,
  onActivate,
}: {
  gains: number[]
  enabled: boolean
  onGainChange: (gain: number, index: number) => void
  /** Dragging a disabled EQ switches it on first, like iOS. */
  onActivate: () => void
}) {
  const containerRef = useRef<HTMLDivElement>(null)
  const svgRef = useRef<SVGSVGElement>(null)
  const { width, plotInset } = useChartGeometry(containerRef)
  const [activeBand, setActiveBand] = useState<number | null>(null)
  const [hoveredBand, setHoveredBand] = useState<number | null>(null)
  const displayedGains = useAnimatedGains(gains, activeBand === null)
  /** The band the readout and the enlarged handle belong to. */
  const focusBand = activeBand ?? hoveredBand

  const plotWidth = Math.max(1, width - plotInset * 2)
  const bandX = (index: number) => plotInset + (plotWidth * index) / LAST_BAND
  const points: Point[] = EQUALIZER_BANDS.map((band) => ({
    x: bandX(band.id),
    y: MID_Y - ((displayedGains[band.id] ?? 0) / MAX_GAIN) * GAIN_SPAN,
  }))

  const adjust = useCallback(
    (index: number, clientY: number) => {
      const rect = svgRef.current?.getBoundingClientRect()
      if (!rect) return
      const normalized = (MID_Y - (clientY - rect.top)) / GAIN_SPAN
      const raw = Math.min(MAX_GAIN, Math.max(-MAX_GAIN, normalized * MAX_GAIN))
      onGainChange(Math.round(raw / GAIN_STEP) * GAIN_STEP, index)
    },
    [onGainChange],
  )

  const onPointerDown = (event: React.PointerEvent<SVGSVGElement>) => {
    const rect = svgRef.current?.getBoundingClientRect()
    if (!rect) return
    event.currentTarget.setPointerCapture(event.pointerId)
    if (!enabled) onActivate()
    const progress = Math.min(1, Math.max(0, (event.clientX - rect.left - plotInset) / plotWidth))
    const index = Math.round(progress * LAST_BAND)
    setActiveBand(index)
    adjust(index, event.clientY)
  }

  /** Nearest handle within `HOVER_RADIUS` of the pointer, if any. */
  const handleUnder = (event: React.PointerEvent<SVGSVGElement>): number | null => {
    if (event.pointerType === "touch") return null
    const rect = svgRef.current?.getBoundingClientRect()
    if (!rect) return null
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    let nearest: number | null = null
    let nearestDistance = HOVER_RADIUS
    points.forEach((point, index) => {
      const distance = Math.hypot(point.x - x, point.y - y)
      if (distance <= nearestDistance) {
        nearest = index
        nearestDistance = distance
      }
    })
    return nearest
  }

  const onPointerMove = (event: React.PointerEvent<SVGSVGElement>) => {
    if (activeBand !== null) {
      adjust(activeBand, event.clientY)
      return
    }
    setHoveredBand(handleUnder(event))
  }

  const endDrag = (event: React.PointerEvent<SVGSVGElement>) => {
    setActiveBand(null)
    // The pointer often ends up resting on the handle it just moved.
    setHoveredBand(handleUnder(event))
  }

  const nudge = (index: number, delta: number) => {
    if (!enabled) onActivate()
    onGainChange(Math.min(MAX_GAIN, Math.max(-MAX_GAIN, (gains[index] ?? 0) + delta)), index)
  }

  const accent = enabled ? "var(--brand)" : "var(--muted-foreground)"

  return (
    <div
      ref={containerRef}
      // Bleeds into the page gutter on phones (like iOS running to the screen
      // edge) and further into the empty page margins on wider viewports, where
      // the extra width is spent entirely on the edge fade.
      className="relative -mx-5 select-none md:-mx-10 xl:-mx-16"
      style={{ height: HEIGHT }}
    >
      <svg
        ref={svgRef}
        width={width}
        height={HEIGHT}
        className="block touch-none"
        style={{ cursor: hoveredBand === null ? undefined : "ns-resize" }}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onPointerLeave={() => setHoveredBand(null)}
      >
        <defs>
          <linearGradient id="eq-curve-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={accent} stopOpacity={enabled ? 0.25 : 0.1} />
            <stop offset="100%" stopColor={accent} stopOpacity={0} />
          </linearGradient>

          {/* Everything that runs edge to edge dissolves into the margins
              instead of being clipped — the outermost band still lands on
              fully opaque ink. */}
          <linearGradient id="eq-edge-fade" gradientUnits="userSpaceOnUse" x1={0} y1={0} x2={width} y2={0}>
            {edgeFadeStops(width, plotInset).map(({ offset, opacity }) => (
              <stop key={offset} offset={offset} stopColor="white" stopOpacity={opacity} />
            ))}
          </linearGradient>
          <mask id="eq-edge-mask">
            <rect x={0} y={0} width={width} height={HEIGHT} fill="url(#eq-edge-fade)" />
          </mask>
        </defs>

        <g mask="url(#eq-edge-mask)">
          {/* Grid: dashed decibel rules with a solid line at 0 dB, plus band guides. */}
          <g stroke="var(--muted-foreground)" fill="none">
            {[0, 1, 2, 3, 4].map((level) => {
              const y = TOP_INSET + (PLOT_HEIGHT * level) / 4
              return (
                <line
                  key={level}
                  x1={0}
                  x2={width}
                  y1={y}
                  y2={y}
                  strokeOpacity={level === 2 ? 0.22 : 0.1}
                  strokeDasharray={level === 2 ? undefined : "3 6"}
                />
              )
            })}
            {points.map((point, index) => (
              <line
                key={index}
                x1={point.x}
                x2={point.x}
                y1={TOP_INSET}
                y2={PLOT_BOTTOM}
                strokeOpacity={0.07}
                strokeDasharray="2 7"
              />
            ))}
          </g>

          <path d={fillPath(points, width)} fill="url(#eq-curve-fill)" />
          <path
            d={curvePath(points, width)}
            fill="none"
            stroke={accent}
            strokeOpacity={enabled ? 1 : 0.55}
            strokeWidth={3}
            strokeLinecap="round"
            strokeLinejoin="round"
            style={{ filter: enabled ? "drop-shadow(0 0 6px color-mix(in srgb, var(--brand) 40%, transparent))" : undefined }}
          />
        </g>

        {points.map((point, index) => {
          const isFocused = focusBand === index
          const isDragging = activeBand === index
          return (
            <g key={index}>
              {/* Stem from the 0 dB line to the handle. */}
              <line
                x1={point.x}
                x2={point.x}
                y1={MID_Y}
                y2={point.y}
                stroke="var(--brand)"
                strokeOpacity={enabled ? (isFocused ? 0.22 : 0.1) : 0}
                strokeWidth={1}
              />
              <circle
                cx={point.x}
                cy={point.y}
                r={9}
                fill={accent}
                stroke="var(--background)"
                strokeWidth={3}
                style={{
                  transformOrigin: `${point.x}px ${point.y}px`,
                  transform: `scale(${isDragging ? 1.33 : isFocused ? 1.18 : 1})`,
                  transition: "transform 180ms var(--ease-snappy)",
                  filter: enabled
                    ? `drop-shadow(0 2px ${isFocused ? 7 : 3}px color-mix(in srgb, var(--brand) ${
                        isFocused ? 45 : 25
                      }%, transparent))`
                    : undefined,
                }}
              />
            </g>
          )
        })}

        {/* Band ticks and frequency labels below the plot. */}
        {EQUALIZER_BANDS.map((band) => {
          const isFocused = focusBand === band.id
          return (
            <g key={band.id}>
              <line
                x1={bandX(band.id)}
                x2={bandX(band.id)}
                y1={PLOT_BOTTOM + 6}
                y2={PLOT_BOTTOM + 12}
                stroke={isFocused ? "var(--brand)" : "var(--muted-foreground)"}
                strokeOpacity={isFocused ? 1 : 0.45}
                strokeWidth={1}
              />
              <text
                x={bandX(band.id)}
                y={PLOT_BOTTOM + 25}
                textAnchor="middle"
                fontSize={11}
                fontWeight={600}
                fill={isFocused ? "var(--brand)" : "var(--muted-foreground)"}
                style={{ fontVariantNumeric: "tabular-nums" }}
              >
                {band.label}Hz
              </text>
            </g>
          )
        })}

      </svg>

      {/* Value readout above the handle being dragged or hovered. */}
      {focusBand !== null && enabled && (
        <div
          // `transition-none` matters: a transition here would let the bubble
          // drift behind the handle instead of moving with it.
          className="pointer-events-none absolute flex h-6 -translate-x-1/2 items-center rounded-[7px] bg-brand px-[7px] text-[11px] font-bold tabular-nums text-background transition-none duration-150 animate-in fade-in-0 zoom-in-90"
          style={{
            left: points[focusBand].x,
            top: Math.max(2, points[focusBand].y - 45),
          }}
        >
          {formatGain(gains[focusBand] ?? 0)}
        </div>
      )}

      {/* Keyboard/assistive layer: one adjustable control per band. It stays
          pointer-transparent so dragging is handled by the SVG below. */}
      <div className="pointer-events-none absolute inset-0">
        {EQUALIZER_BANDS.map((band) => (
          <div
            key={band.id}
            role="slider"
            tabIndex={0}
            aria-label={`${band.character}, ${band.label} hertz`}
            aria-valuemin={-MAX_GAIN}
            aria-valuemax={MAX_GAIN}
            aria-valuenow={gains[band.id] ?? 0}
            aria-valuetext={enabled ? formatGain(gains[band.id] ?? 0) : "EQ off"}
            onKeyDown={(event) => {
              if (event.key === "ArrowUp" || event.key === "ArrowRight") nudge(band.id, GAIN_STEP)
              else if (event.key === "ArrowDown" || event.key === "ArrowLeft") nudge(band.id, -GAIN_STEP)
              else return
              event.preventDefault()
            }}
            className="absolute rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-brand/70"
            style={{
              left: bandX(band.id) - Math.max(36, plotWidth / EQUALIZER_BANDS.length) / 2,
              top: TOP_INSET,
              width: Math.max(36, plotWidth / EQUALIZER_BANDS.length),
              height: PLOT_HEIGHT,
            }}
          />
        ))}
      </div>
    </div>
  )
}

/**
 * Mirrored gradient stops that feather the plot into the left/right margins.
 * Smoothstep keeps the slope at zero on both ends, so neither the outer tip of
 * the curve nor the point where it reaches full strength shows a seam.
 */
function edgeFadeStops(width: number, inset: number): { offset: number; opacity: number }[] {
  const safeWidth = Math.max(width, inset * 2 + 1)
  const ramp = Array.from({ length: EDGE_FADE_STEPS + 1 }, (_, step) => {
    const distance = step / EDGE_FADE_STEPS
    return { offset: (distance * inset) / safeWidth, opacity: distance * distance * (3 - 2 * distance) }
  })
  return [
    ...ramp,
    ...[...ramp].reverse().map(({ offset, opacity }) => ({ offset: 1 - offset, opacity })),
  ]
}

/** iOS `smoothPath`: quad curves through the band midpoints, flat to the edges. */
function curvePath(points: Point[], width: number): string {
  const round = (value: number) => Math.round(value * 100) / 100
  const first = points[0]
  const last = points[LAST_BAND]
  let path = `M 0 ${round(first.y)} L ${round(first.x)} ${round(first.y)}`
  for (let index = 1; index < points.length; index++) {
    const previous = points[index - 1]
    const current = points[index]
    path += ` Q ${round(previous.x)} ${round(previous.y)} ${round((previous.x + current.x) / 2)} ${round(
      (previous.y + current.y) / 2,
    )}`
    if (index === LAST_BAND) path += ` Q ${round(current.x)} ${round(current.y)} ${round(current.x)} ${round(current.y)}`
  }
  return `${path} L ${round(width)} ${round(last.y)}`
}

function fillPath(points: Point[], width: number): string {
  return `${curvePath(points, width)} L ${width} ${PLOT_BOTTOM} L 0 ${PLOT_BOTTOM} Z`
}

/**
 * The chart is wider than the text column it sits in (see the negative margins
 * on the container). Whatever it bleeds past the column becomes fade runway on
 * top of the iOS inset, which keeps the plot the same size at every width.
 */
function useChartGeometry(ref: React.RefObject<HTMLElement | null>) {
  const [geometry, setGeometry] = useState({ width: 0, plotInset: BASE_PLOT_INSET })

  useLayoutEffect(() => {
    const element = ref.current
    const column = element?.parentElement
    if (!element || !column) return
    const measure = () => {
      const width = element.clientWidth
      const bleed = Math.max(0, (width - column.clientWidth) / 2)
      setGeometry({ width, plotInset: BASE_PLOT_INSET + bleed })
    }
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    observer.observe(column)
    return () => observer.disconnect()
  }, [ref])

  return geometry
}

/**
 * Eases the drawn curve toward the target gains (iOS animates preset changes
 * with a 0.32s smooth curve). While dragging, the target is returned verbatim
 * rather than through state, so the curve, handle and value bubble all land in
 * the same paint as the pointer move.
 */
function useAnimatedGains(target: number[], animate: boolean): number[] {
  const [displayed, setDisplayed] = useState(target)
  const displayedRef = useRef(target)
  const frameRef = useRef(0)

  useEffect(() => {
    const from = displayedRef.current
    const settle = () => {
      displayedRef.current = target
      setDisplayed(target)
    }
    if (!animate || from.every((value, index) => Math.abs(value - target[index]) < 0.001)) {
      settle()
      return
    }

    const start = performance.now()
    const tick = (now: number) => {
      const progress = Math.min(1, (now - start) / CURVE_DURATION)
      const eased = 1 - (1 - progress) ** 3
      const next = target.map((value, index) => from[index] + (value - from[index]) * eased)
      displayedRef.current = next
      setDisplayed(next)
      if (progress < 1) frameRef.current = requestAnimationFrame(tick)
    }
    frameRef.current = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frameRef.current)
  }, [target, animate])

  return animate ? displayed : target
}
