/**
 * 1:1 port of the iOS `WaveformAnalyzer`.
 *
 * The iOS pipeline (AVAudioFile → Float32 PCM → per-bar RMS):
 *   1. Decode the file to non-interleaved Float32 PCM.
 *   2. `framesPerBar = max(1, totalFrames / targetBars)`; remainder frames
 *      accumulate into the last bar (`barIdx = min(targetBars-1, f / framesPerBar)`).
 *   3. Per frame: `power = mean(sample² across channels)`.
 *   4. Per bar: `RMS = sqrt(mean(power))` (Double accumulation, like iOS).
 *   5. Normalize by the peak bar.
 *   6. Clamp quiet bars to 0.05 so silence stays visible.
 *
 * Every arithmetic step matches, so lossless sources (WAV/AIFF/FLAC) produce
 * byte-identical waveform payloads. Lossy sources (M4A/MP3) may differ by at
 * most a quantization step depending on the browser's decoder — visually
 * indistinguishable from an iOS import.
 */
export interface AnalyzedAudio {
  duration: number
  /** Normalized amplitude bars (0…1); empty when the browser can't decode the file. */
  waveform: number[]
}

export async function analyzeAudioFile(file: File, targetBars = 200): Promise<AnalyzedAudio> {
  let buffer: AudioBuffer
  try {
    // A fixed 44.1 kHz offline context keeps decoding deterministic across
    // machines (decodeAudioData resamples to the context rate). The envelope
    // math below is frame-count-relative, matching the iOS analyzer.
    const context = new OfflineAudioContext(1, 1, 44_100)
    buffer = await context.decodeAudioData(await file.arrayBuffer())
  } catch {
    // Mirrors iOS: analysis failures still import the track (`waveform ?? []`).
    return { duration: 0, waveform: [] }
  }

  return { duration: buffer.duration, waveform: extractBars(buffer, targetBars) }
}

function extractBars(buffer: AudioBuffer, targetBars: number): number[] {
  const totalFrames = buffer.length
  const channelCount = buffer.numberOfChannels
  if (totalFrames <= 0 || channelCount <= 0) return []

  const channels: Float32Array[] = []
  for (let c = 0; c < channelCount; c++) channels.push(buffer.getChannelData(c))

  const framesPerBar = Math.max(1, Math.floor(totalFrames / targetBars))
  const barSumSq = new Float64Array(targetBars)
  const barCount = new Int32Array(targetBars)

  for (let f = 0; f < totalFrames; f++) {
    let sumSq = 0
    for (let c = 0; c < channelCount; c++) {
      const v = channels[c][f]
      sumSq += v * v
    }
    const power = sumSq / channelCount
    const barIdx = Math.min(targetBars - 1, Math.floor(f / framesPerBar))
    barSumSq[barIdx] += power
    barCount[barIdx] += 1
  }

  // RMS per bar — Math.fround mirrors the iOS casts to 32-bit Float
  // (`Float(sqrt(sumSq / Double(n)))` and Float division during normalization).
  let bars = new Array<number>(targetBars)
  for (let i = 0; i < targetBars; i++) {
    bars[i] = barCount[i] > 0 ? Math.fround(Math.sqrt(barSumSq[i] / barCount[i])) : 0
  }

  const peak = Math.max(...bars)
  if (peak > 0) bars = bars.map((b) => Math.min(1, Math.fround(b / peak)))

  // Clamp very quiet bars to a minimum visible height so silence isn't invisible.
  const minHeight = Math.fround(0.05)
  return bars.map((b) => Math.max(minHeight, b))
}
