import AVFoundation
import Foundation

/// Extracts a normalized amplitude envelope from an audio file using AVAssetReader.
/// Downsamples to 11 025 Hz mono PCM to keep processing fast regardless of source format.
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
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        // Grab the first audio track synchronously via a semaphore-bridged async call.
        var audioTrack: AVAssetTrack?
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
            sema.signal()
        }
        sema.wait()

        guard let track = audioTrack else { return [] }

        // Output as 11 025 Hz mono 16-bit PCM — reduces data ~4× vs 44.1 kHz.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 11_025.0,
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return [] }

        // --- Streaming RMS accumulation ---
        // Estimate total sample count from asset duration to size chunks upfront.
        let estimatedDuration = CMTimeGetSeconds(asset.duration)
        let estimatedSamples = max(1, Int(estimatedDuration * 11_025))
        let chunkSize = max(1, estimatedSamples / targetBars)

        var barSumSq = [Double](repeating: 0, count: targetBars)
        var barCount  = [Int](repeating: 0, count: targetBars)
        var sampleCursor: Int = 0

        while reader.status == .reading {
            guard let sb = output.copyNextSampleBuffer() else { break }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }

            let byteLen = CMBlockBufferGetDataLength(bb)
            var raw = Data(count: byteLen)
            raw.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: byteLen, destination: $0.baseAddress!)
            }

            raw.withUnsafeBytes { ptr in
                let samples = ptr.bindMemory(to: Int16.self)
                for s in samples {
                    let barIdx = min(targetBars - 1, sampleCursor / chunkSize)
                    let v = Double(s)
                    barSumSq[barIdx] += v * v
                    barCount[barIdx] += 1
                    sampleCursor += 1
                }
            }
        }

        // Compute RMS per bar, normalize to 0…1.
        var bars = zip(barSumSq, barCount).map { sumSq, n -> Float in
            guard n > 0 else { return 0 }
            return Float(sqrt(sumSq / Double(n))) / Float(Int16.max)
        }

        let peak = bars.max() ?? 0
        if peak > 0 { bars = bars.map { min(1, $0 / peak) } }

        // Clamp very quiet bars to a minimum visible height so silence isn't invisible.
        return bars.map { max(0.05, $0) }
    }
}
