import Compression
import Foundation

/// Serializes a normalized waveform envelope (`[Float]` in 0…1) into a compact
/// base64 string suitable for storing directly on a Firestore track document.
///
/// Pipeline: quantize each bar to a single byte (0…255), DEFLATE-compress the
/// byte stream, then base64-encode. A 200-bar waveform typically ends up around
/// 150–250 characters — small enough to live inline in the track document so the
/// waveform is available immediately on every device without re-analyzing audio.
enum WaveformCodec {

    /// Quantization scale: floats in 0…1 map onto 0…255.
    private static let quantScale: Float = 255

    static func encode(_ bars: [Float]) -> String? {
        guard !bars.isEmpty else { return nil }

        var bytes = [UInt8](repeating: 0, count: bars.count)
        for (i, value) in bars.enumerated() {
            let clamped = min(1, max(0, value))
            bytes[i] = UInt8((clamped * quantScale).rounded())
        }

        guard let compressed = deflate(bytes) else { return nil }
        return compressed.base64EncodedString()
    }

    static func decode(_ string: String) -> [Float]? {
        guard !string.isEmpty,
              let compressed = Data(base64Encoded: string),
              let bytes = inflate(compressed),
              !bytes.isEmpty
        else { return nil }

        return bytes.map { Float($0) / quantScale }
    }

    // MARK: - DEFLATE (Compression framework)

    /// Output layout: 4-byte little-endian uncompressed length, then the raw
    /// DEFLATE stream. The length header lets `inflate` size its buffer exactly.
    private static func deflate(_ input: [UInt8]) -> Data? {
        let capacity = input.count + (input.count / 2) + 64
        var dst = [UInt8](repeating: 0, count: capacity)

        let written = input.withUnsafeBufferPointer { src in
            compression_encode_buffer(&dst, capacity, src.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }

        var out = Data(capacity: written + 4)
        let n = UInt32(input.count)
        out.append(UInt8(n & 0xff))
        out.append(UInt8((n >> 8) & 0xff))
        out.append(UInt8((n >> 16) & 0xff))
        out.append(UInt8((n >> 24) & 0xff))
        out.append(contentsOf: dst[0..<written])
        return out
    }

    private static func inflate(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }

        let originalCount = Int(bytes[0])
            | (Int(bytes[1]) << 8)
            | (Int(bytes[2]) << 16)
            | (Int(bytes[3]) << 24)
        // Guard against corrupt headers requesting absurd allocations.
        guard originalCount > 0, originalCount < 1_000_000 else { return nil }

        let compressed = Array(bytes[4...])
        var dst = [UInt8](repeating: 0, count: originalCount)

        let written = compressed.withUnsafeBufferPointer { src in
            compression_decode_buffer(&dst, originalCount, src.baseAddress!, compressed.count, nil, COMPRESSION_ZLIB)
        }
        guard written == originalCount else { return nil }
        return dst
    }
}
