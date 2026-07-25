export const COVER_PHOTO_LIMITS = {
  maxDimension: 1200,
  initialQuality: 0.82,
  minimumQuality: 0.62,
  maxBytes: 1_500_000,
} as const

export const PROFILE_PHOTO_LIMITS = {
  maxDimension: 512,
  initialQuality: 0.82,
  minimumQuality: 0.62,
  maxBytes: 500_000,
} as const

type SquareJpegOptions = {
  maxDimension: number
  initialQuality: number
  minimumQuality: number
  maxBytes: number
}

/**
 * Center-crops to a square and encodes an opaque JPEG. Quality is reduced only
 * when necessary, keeping ordinary photos sharp while bounding noisy images.
 */
export async function compressedSquareJpeg(
  bitmap: ImageBitmap,
  options: SquareJpegOptions,
): Promise<Blob> {
  const sourceSide = Math.min(bitmap.width, bitmap.height)
  let targetSide = Math.min(options.maxDimension, sourceSide)

  while (targetSide >= 128) {
    const canvas = renderSquare(bitmap, sourceSide, targetSide)
    let quality = options.initialQuality

    while (true) {
      const blob = await canvasJpeg(canvas, quality)
      if (blob.size <= options.maxBytes) return blob
      if (quality <= options.minimumQuality) break
      quality = Math.max(options.minimumQuality, quality - 0.06)
    }

    targetSide = Math.floor(targetSide * 0.82)
  }

  throw new Error("Image couldn't be compressed to the upload limit.")
}

function renderSquare(
  bitmap: ImageBitmap,
  sourceSide: number,
  targetSide: number,
): HTMLCanvasElement {
  const canvas = document.createElement("canvas")
  canvas.width = targetSide
  canvas.height = targetSide

  const context = canvas.getContext("2d")
  if (!context) throw new Error("Canvas is unavailable.")

  context.fillStyle = "#000"
  context.fillRect(0, 0, targetSide, targetSide)
  context.drawImage(
    bitmap,
    (bitmap.width - sourceSide) / 2,
    (bitmap.height - sourceSide) / 2,
    sourceSide,
    sourceSide,
    0,
    0,
    targetSide,
    targetSide,
  )
  return canvas
}

function canvasJpeg(canvas: HTMLCanvasElement, quality: number): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => (blob ? resolve(blob) : reject(new Error("Image encoding failed."))),
      "image/jpeg",
      quality,
    )
  })
}
