import SwiftUI
import UIKit

enum ProjectAccentColor {
    private static let fallbackHex = "#667EEA"

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

    static func hex(from image: UIImage) -> String {
        let size = CGSize(width: 48, height: 48)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        guard let cgImage = thumbnail.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data)
        else { return fallbackHex }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return fallbackHex }

        var bestScore = -Double.infinity
        var bestRGB = (r: 0.4, g: 0.35, b: 0.85)

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                let r = Double(bytes[offset]) / 255
                let g = Double(bytes[offset + 1]) / 255
                let b = Double(bytes[offset + 2]) / 255
                let score = pixelAccentScore(r: r, g: g, b: b)
                if score > bestScore {
                    bestScore = score
                    bestRGB = (r, g, b)
                }
            }
        }

        return tunedHex(rgb: bestRGB)
    }

    static func color(hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return Color(hex: fallbackHex) }
        return Color(hex: hex)
    }

    // MARK: - Image scoring

    private static func pixelAccentScore(r: Double, g: Double, b: Double) -> Double {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let sat = Double(saturation)
        let bri = Double(brightness)
        guard sat > 0.12, bri > 0.28, bri < 0.95 else { return -1 }

        let saturationScore = min(sat * 1.1, 1)
        let brightnessScore = 1 - abs(bri - 0.68) / 0.68
        return saturationScore * 0.45 + brightnessScore * 0.55
    }

    // MARK: - Tuning

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

        let sat = min(max(Double(saturation) * 1.04, 0.40), 0.86)
        let bri = min(max(Double(brightness) * 1.08, 0.52), 0.78)
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
