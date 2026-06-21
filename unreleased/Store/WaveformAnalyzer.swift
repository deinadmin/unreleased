import AVFoundation
import Foundation

/// Extracts a normalized amplitude envelope from an audio file.
///
/// Uses `AVAudioFile`, which decodes any supported container (m4a, wav, aiff,
/// mp3, …) into a canonical non-interleaved Float32 buffer. This avoids the
/// `AVAssetReader` sample-rate/channel conversions that silently yield no
/// samples for already-LPCM sources such as WAV.
enum WaveformAnalyzer {

    /// Analyze the file at `url` and return `targetBars` normalized amplitude values (0…1).
    /// Runs off the main actor so it never blocks the UI.
    static func analyze(url: URL, targetBars: Int = 200) async -> [Float] {
        await Task.detached(priority: .userInitiated) {
            (try? Self.extractBars(url: url, targetBars: targetBars)) ?? []
        }.value
    }

    // MARK: - Core extraction (runs on background thread)

    private static func extractBars(url: URL, targetBars: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        // processingFormat is always deinterleaved Float32 at the file's native
        // sample rate / channel count — samples are already in -1…1.
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        let channelCount = Int(format.channelCount)
        guard totalFrames > 0, channelCount > 0 else { return [] }

        let framesPerBar = max(1, totalFrames / targetBars)

        var barSumSq = [Double](repeating: 0, count: targetBars)
        var barCount = [Int](repeating: 0, count: targetBars)
        var frameCursor = 0

        let bufferCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferCapacity) else {
            return []
        }

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channels = buffer.floatChannelData else { break }

            for f in 0..<frames {
                var sumSq = 0.0
                for c in 0..<channelCount {
                    let v = Double(channels[c][f])
                    sumSq += v * v
                }
                let power = sumSq / Double(channelCount)
                let barIdx = min(targetBars - 1, frameCursor / framesPerBar)
                barSumSq[barIdx] += power
                barCount[barIdx] += 1
                frameCursor += 1
            }
        }

        // RMS per bar (float samples are already normalized to 0…1).
        var bars = zip(barSumSq, barCount).map { sumSq, n -> Float in
            guard n > 0 else { return 0 }
            return Float(sqrt(sumSq / Double(n)))
        }

        let peak = bars.max() ?? 0
        if peak > 0 { bars = bars.map { min(1, $0 / peak) } }

        // Clamp very quiet bars to a minimum visible height so silence isn't invisible.
        return bars.map { max(0.05, $0) }
    }
}
