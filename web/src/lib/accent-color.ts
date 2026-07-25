import type { GradientTheme } from "./types"

/**
 * Web port of the iOS `ProjectAccentColor`: accent hex from a gradient
 * (midpoint of first/last stop) or from a cover image (dominant colors,
 * excluding black/white/gray, sorted by frequency) — both passed through the
 * same saturation/brightness tuning.
 */

const FALLBACK_HEX = "#667EEA"

export function accentHexFromGradient(gradient: GradientTheme): string {
  const colors = gradient.colors
  if (colors.length === 0) return FALLBACK_HEX
  if (colors.length === 1) return tunedHex(rgbFromHex(colors[0]))
  const start = rgbFromHex(colors[0])
  const end = rgbFromHex(colors[colors.length - 1])
  return tunedHex({
    r: (start.r + end.r) / 2,
    g: (start.g + end.g) / 2,
    b: (start.b + end.b) / 2,
  })
}

/** Single most dominant accent hex from a cover image. */
export function accentHexFromImage(image: CanvasImageSource & { width: number; height: number }): string {
  const colors = extractDominantColors(image, 1)
  return colors.length > 0 ? tunedHex(colors[0]) : FALLBACK_HEX
}

/** Two dominant colors forming the vinyl gradient (iOS `gradientHexPair`). */
export function gradientHexPairFromImage(
  image: CanvasImageSource & { width: number; height: number },
): [string, string] {
  const colors = extractDominantColors(image, 2)
  const start = colors.length > 0 ? tunedHex(colors[0]) : FALLBACK_HEX
  const end = colors.length > 1 ? tunedHex(colors[1]) : start
  return [start, end]
}

// MARK: - Dominant color extraction
// Approximates the DominantColors package: pixelate, drop black/white/gray,
// cluster similar colors, sort clusters by pixel frequency.

interface RGB {
  r: number
  g: number
  b: number
}

function extractDominantColors(
  image: CanvasImageSource & { width: number; height: number },
  count: number,
): RGB[] {
  const size = 64
  const canvas = document.createElement("canvas")
  canvas.width = size
  canvas.height = size
  const ctx = canvas.getContext("2d")
  if (!ctx) return []
  ctx.drawImage(image, 0, 0, size, size)

  let data: Uint8ClampedArray
  try {
    data = ctx.getImageData(0, 0, size, size).data
  } catch {
    return []
  }

  // Cluster into 4-bit-per-channel buckets, averaging members.
  const buckets = new Map<number, { count: number; r: number; g: number; b: number }>()
  for (let i = 0; i < data.length; i += 4) {
    const r = data[i] / 255
    const g = data[i + 1] / 255
    const b = data[i + 2] / 255
    if (data[i + 3] < 128) continue

    const { s, v } = rgbToHsv(r, g, b)
    // Mirrors DominantColors' excludeBlack / excludeWhite / excludeGray options.
    if (v < 0.15) continue
    if (v > 0.95 && s < 0.12) continue
    if (s < 0.12) continue

    const key = ((data[i] >> 4) << 8) | ((data[i + 1] >> 4) << 4) | (data[i + 2] >> 4)
    const bucket = buckets.get(key)
    if (bucket) {
      bucket.count++
      bucket.r += r
      bucket.g += g
      bucket.b += b
    } else {
      buckets.set(key, { count: 1, r, g, b })
    }
  }

  return [...buckets.values()]
    .sort((a, b) => b.count - a.count)
    .slice(0, count)
    .map((bucket) => ({
      r: bucket.r / bucket.count,
      g: bucket.g / bucket.count,
      b: bucket.b / bucket.count,
    }))
}

// MARK: - Tuning (identical clamps to the iOS `tunedHex`)

function tunedHex(rgb: RGB): string {
  const { h, s, v } = rgbToHsv(rgb.r, rgb.g, rgb.b)
  const sat = Math.min(Math.max(s * 1.05, 0.42), 0.88)
  const bri = Math.min(Math.max(v * 1.06, 0.5), 0.8)
  const tuned = hsvToRgb(h, sat, bri)
  const c = (x: number) =>
    Math.round(Math.min(1, Math.max(0, x)) * 255)
      .toString(16)
      .padStart(2, "0")
      .toUpperCase()
  return `#${c(tuned.r)}${c(tuned.g)}${c(tuned.b)}`
}

function rgbFromHex(hex: string): RGB {
  const cleaned = hex.replace(/[^0-9a-fA-F]/g, "")
  const expanded =
    cleaned.length === 3 ? cleaned.split("").map((ch) => ch + ch).join("") : cleaned
  const int = parseInt(expanded, 16) || 0
  return { r: ((int >> 16) & 0xff) / 255, g: ((int >> 8) & 0xff) / 255, b: (int & 0xff) / 255 }
}

function rgbToHsv(r: number, g: number, b: number): { h: number; s: number; v: number } {
  const max = Math.max(r, g, b)
  const min = Math.min(r, g, b)
  const delta = max - min
  let h = 0
  if (delta > 0) {
    if (max === r) h = ((g - b) / delta) % 6
    else if (max === g) h = (b - r) / delta + 2
    else h = (r - g) / delta + 4
    h /= 6
    if (h < 0) h += 1
  }
  return { h, s: max === 0 ? 0 : delta / max, v: max }
}

function hsvToRgb(h: number, s: number, v: number): RGB {
  const i = Math.floor(h * 6)
  const f = h * 6 - i
  const p = v * (1 - s)
  const q = v * (1 - f * s)
  const t = v * (1 - (1 - f) * s)
  switch (i % 6) {
    case 0:
      return { r: v, g: t, b: p }
    case 1:
      return { r: q, g: v, b: p }
    case 2:
      return { r: p, g: v, b: t }
    case 3:
      return { r: p, g: q, b: v }
    case 4:
      return { r: t, g: p, b: v }
    default:
      return { r: v, g: p, b: q }
  }
}
