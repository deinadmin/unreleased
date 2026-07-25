/**
 * Decodes the waveform payload written by the iOS app's `WaveformCodec`:
 * base64( 4-byte little-endian uncompressed length + raw DEFLATE stream ).
 * Bars are single bytes quantized 0…255, normalized back to 0…1 floats.
 */
export async function decodeWaveform(encoded: string): Promise<number[] | undefined> {
  try {
    const raw = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0))
    if (raw.length <= 4) return undefined
    const expected = raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24)
    if (expected <= 0 || expected >= 1_000_000) return undefined
    const compressed = raw.subarray(4)
    const bytes =
      (await inflate(compressed, "deflate-raw")) ?? (await inflate(compressed, "deflate"))
    if (!bytes || bytes.length === 0) return undefined
    return Array.from(bytes, (b) => b / 255)
  } catch {
    return undefined
  }
}

async function inflate(
  data: Uint8Array,
  format: CompressionFormat,
): Promise<Uint8Array | undefined> {
  try {
    const stream = new Blob([data as BlobPart]).stream().pipeThrough(new DecompressionStream(format))
    return new Uint8Array(await new Response(stream).arrayBuffer())
  } catch {
    return undefined
  }
}

/**
 * Encodes a waveform exactly like the iOS `WaveformCodec.encode`:
 * quantize each bar to a byte (0…255), raw-DEFLATE the byte stream
 * (Apple's `COMPRESSION_ZLIB` emits raw DEFLATE), prefix a 4-byte
 * little-endian uncompressed length, then base64.
 */
export async function encodeWaveform(bars: number[]): Promise<string | undefined> {
  if (bars.length === 0) return undefined
  const bytes = new Uint8Array(bars.length)
  for (let i = 0; i < bars.length; i++) {
    bytes[i] = Math.round(Math.min(1, Math.max(0, bars[i])) * 255)
  }

  const stream = new Blob([bytes as BlobPart])
    .stream()
    .pipeThrough(new CompressionStream("deflate-raw"))
  const compressed = new Uint8Array(await new Response(stream).arrayBuffer())

  const out = new Uint8Array(4 + compressed.length)
  out[0] = bytes.length & 0xff
  out[1] = (bytes.length >> 8) & 0xff
  out[2] = (bytes.length >> 16) & 0xff
  out[3] = (bytes.length >> 24) & 0xff
  out.set(compressed, 4)

  let binary = ""
  for (let i = 0; i < out.length; i++) binary += String.fromCharCode(out[i])
  return btoa(binary)
}

/** Linear resample matching the iOS `resample(_:to:)` implementation. */
export function resampleBars(source: number[], targetCount: number): number[] {
  if (targetCount <= 0 || source.length === 0) return []
  if (source.length === targetCount) return source
  const ratio = (source.length - 1) / Math.max(1, targetCount - 1)
  return Array.from({ length: targetCount }, (_, i) => {
    const pos = i * ratio
    const lo = Math.floor(pos)
    const hi = Math.min(lo + 1, source.length - 1)
    const frac = pos - lo
    return source[lo] * (1 - frac) + source[hi] * frac
  })
}

/**
 * Deterministic placeholder bars seeded from the track UUID — same FNV-1a +
 * LCG construction as the iOS app so both platforms show identical bars.
 */
export function seededBars(count: number, trackID: string): number[] {
  let state = stableSeed(trackID)
  if (state === 0n) state = 0x9e3779b97f4a7c15n
  const next = () => {
    state = (state * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn
    const v = (state >> 33n) ^ state
    return Number(v) / Number(0xffffffffffffffffn)
  }
  next()
  return Array.from({ length: count }, () => 0.1 + next() * 0.9)
}

function stableSeed(uuid: string): bigint {
  const hex = uuid.replace(/-/g, "")
  let hash = 0xcbf29ce484222325n
  const prime = 0x100000001b3n
  for (let i = 0; i < 16; i++) {
    const byte = BigInt(parseInt(hex.slice(i * 2, i * 2 + 2), 16) || 0)
    hash = ((hash ^ byte) * prime) & 0xffffffffffffffffn
  }
  return hash
}
