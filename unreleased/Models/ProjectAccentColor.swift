import SwiftUI
import UIKit

enum ProjectAccentColor {
    private static let fallbackHex = "#667EEA"
    private static let fallbackRGB = (r: 0.4, g: 0.49, b: 0.92)

    // MARK: - Public interface

    static func hex(from gradient: GradientTheme) -> String {
        guard !gradient.colors.isEmpty else { return fallbackHex }
        if gradient.colors.count == 1 {
            return tunedHex(gradient.colors[0])
        }
        let start = rgb(from: gradient.colors[0])
        let end = rgb(from: gradient.colors[gradient.colors.count - 1])
        let middle = (
            r: (start.r + end.r) / 2,
            g: (start.g + end.g) / 2,
            b: (start.b + end.b) / 2
        )
        return tunedHex(rgb: middle)
    }

    /// Returns the single best accent hex from a cover image using dominant-color clustering.
    static func hex(from image: UIImage) -> String {
        let colors = dominantColors(from: image, count: 1)
        return tunedHex(rgb: colors[0])
    }

    /// Returns two hex colors from a cover image that make a good gradient.
    /// The pair is chosen to be visually distinct (≥ 30° hue separation).
    static func gradientHexPair(from image: UIImage) -> (String, String) {
        let colors = dominantColors(from: image, count: 2)
        return (tunedHex(rgb: colors[0]), tunedHex(rgb: colors[1]))
    }

    static func color(hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return Color(hex: fallbackHex) }
        return Color(hex: hex)
    }

    // MARK: - Core dominant-color analysis

    /// Extracts up to `count` visually distinct dominant colors using hue-bucket weighted averaging.
    ///
    /// Algorithm:
    /// 1. Renders a 120×120 thumbnail for consistent and fast sampling.
    /// 2. Filters pixels: saturation > 0.15, brightness 0.22–0.96 (ignores near-black/white/grey).
    /// 3. Buckets pixels by hue into 36 bins (10° each), weighting by saturation² × brightness score.
    /// 4. Averages each non-empty bucket to get a representative color.
    /// 5. Selects up to `count` buckets with at least 30° mutual hue separation (most-dominant first).
    private static func dominantColors(
        from image: UIImage,
        count: Int
    ) -> [(r: Double, g: Double, b: Double)] {
        let side = 120
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let cgImage = thumbnail.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return Array(repeating: fallbackRGB, count: count) }

        let width = cgImage.width
        let height = cgImage.height
        let bpp = cgImage.bitsPerPixel / 8
        guard bpp >= 3 else { return Array(repeating: fallbackRGB, count: count) }

        let numBuckets = 36
        var rSum = [Double](repeating: 0, count: numBuckets)
        var gSum = [Double](repeating: 0, count: numBuckets)
        var bSum = [Double](repeating: 0, count: numBuckets)
        var wSum = [Double](repeating: 0, count: numBuckets)

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = y * cgImage.bytesPerRow + x * bpp
                let r = Double(bytes[offset]) / 255
                let g = Double(bytes[offset + 1]) / 255
                let b = Double(bytes[offset + 2]) / 255

                var hue: CGFloat = 0
                var sat: CGFloat = 0
                var bri: CGFloat = 0
                var alpha: CGFloat = 0
                UIColor(red: r, green: g, blue: b, alpha: 1)
                    .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

                let s = Double(sat)
                let v = Double(bri)
                guard s > 0.15, v > 0.22, v < 0.96 else { continue }

                // Pixels close to the brightness sweet-spot (≈0.65) score higher.
                let brightnessScore = max(1.0 - abs(v - 0.65) / 0.65, 0.1)
                let w = s * s * brightnessScore

                let bucket = min(Int(Double(hue) * Double(numBuckets)), numBuckets - 1)
                rSum[bucket] += r * w
                gSum[bucket] += g * w
                bSum[bucket] += b * w
                wSum[bucket] += w
            }
        }

        struct Bucket {
            let index: Int
            let rgb: (r: Double, g: Double, b: Double)
            let weight: Double
        }

        var buckets: [Bucket] = []
        for i in 0..<numBuckets {
            guard wSum[i] > 0 else { continue }
            buckets.append(Bucket(
                index: i,
                rgb: (rSum[i] / wSum[i], gSum[i] / wSum[i], bSum[i] / wSum[i]),
                weight: wSum[i]
            ))
        }

        guard !buckets.isEmpty else { return Array(repeating: fallbackRGB, count: count) }
        buckets.sort { $0.weight > $1.weight }

        if count == 1 { return [buckets[0].rgb] }

        // Select up to `count` buckets with ≥ 30° (3 buckets) mutual hue separation.
        let minSep = numBuckets / 12
        var selected: [Bucket] = [buckets[0]]
        for candidate in buckets.dropFirst() {
            let separated = selected.allSatisfy { existing in
                let diff = abs(existing.index - candidate.index)
                return min(diff, numBuckets - diff) >= minSep
            }
            if separated { selected.append(candidate) }
            if selected.count == count { break }
        }

        while selected.count < count { selected.append(buckets[0]) }
        return selected.map { $0.rgb }
    }

    // MARK: - Tuning

    /// Clamps saturation and brightness into a display-pleasing range.
    private static func tunedHex(_ hex: String) -> String {
        tunedHex(rgb: rgb(from: hex))
    }

    private static func tunedHex(rgb: (r: Double, g: Double, b: Double)) -> String {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let sat = min(max(Double(saturation) * 1.05, 0.42), 0.88)
        let bri = min(max(Double(brightness) * 1.06, 0.50), 0.80)
        let color = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private static func rgb(from hex: String) -> (r: Double, g: Double, b: Double) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (r, g, b) = ((int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        default:
            (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        }
        return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }
}
