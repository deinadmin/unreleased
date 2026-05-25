import SwiftUI
import UIKit
import DominantColors

enum ProjectAccentColor {
    private static let fallbackHex = "#667EEA"

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

    /// Returns the single most dominant accent hex from a cover image.
    static func hex(from image: UIImage) -> String {
        let colors = extract(from: image, count: 1)
        guard let first = colors.first else { return fallbackHex }
        return tunedHex(uiColor: first)
    }

    /// Returns two hex colors from a cover image that form a good gradient.
    /// DominantColors groups visually similar pixels, so the two results are
    /// naturally distinct color clusters sorted by frequency.
    static func gradientHexPair(from image: UIImage) -> (String, String) {
        let colors = extract(from: image, count: 2)
        let start = colors.count > 0 ? tunedHex(uiColor: colors[0]) : fallbackHex
        let end   = colors.count > 1 ? tunedHex(uiColor: colors[1]) : start
        return (start, end)
    }

    static func color(hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return Color(hex: fallbackHex) }
        return Color(hex: hex)
    }

    // MARK: - Extraction via DominantColors

    /// Extracts up to `count` dominant UIColors, excluding black / white / grey,
    /// sorted by pixel frequency. Uses `.fair` quality for a fast pixelate pass.
    private static func extract(from image: UIImage, count: Int) -> [UIColor] {
        let colors = try? DominantColors.dominantColors(
            uiImage: image,
            quality: .fair,
            maxCount: count,
            options: [.excludeBlack, .excludeWhite, .excludeGray],
            sorting: .frequency
        )
        return colors ?? []
    }

    // MARK: - Tuning

    /// Boosts saturation slightly and clamps brightness into a display-pleasing range.
    private static func tunedHex(uiColor: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return tunedHex(rgb: (Double(r), Double(g), Double(b)))
    }

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
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
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
