import SwiftUI
import UIKit

/// Styles a control placed over cover artwork with a readable black or white tint.
struct CoverControlContrastModifier: ViewModifier {
    let coverImage: UIImage?
    let fallbackGradient: GradientTheme?
    let backgroundHex: String?
    let sampleRect: CGRect

    private var usesDarkControl: Bool {
        let luminance: CGFloat
        if let backgroundHex,
           let backgroundLuminance = CoverArtworkLuminance.relativeLuminance(ofHex: backgroundHex) {
            luminance = backgroundLuminance
        } else if let coverImage {
            luminance = CoverArtworkLuminance.relativeLuminance(
                of: coverImage,
                in: sampleRect
            )
        } else if let fallbackGradient {
            let accentHex = ProjectAccentColor.hex(from: fallbackGradient)
            luminance = CoverArtworkLuminance.relativeLuminance(ofHex: accentHex) ?? 0
        } else {
            luminance = 0
        }

        // WCAG contrast ratios for black and white are equal at a relative
        // luminance of approximately 0.179.
        return luminance > 0.179
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(usesDarkControl ? .black : .white)
            // TwoToneCircleSpinner reads this environment value to choose the
            // matching black or white stroke treatment while loading.
            .environment(\.colorScheme, usesDarkControl ? .light : .dark)
    }
}

extension View {
    /// Chooses black controls for light artwork or a light fallback gradient,
    /// and white controls for darker covers.
    ///
    /// `sampleRect` uses normalized artwork coordinates. Keep it tightly aligned
    /// with the area underneath the control so unrelated parts of the cover do
    /// not influence the result.
    func coverControlContrast(
        for coverImage: UIImage?,
        fallbackGradient: GradientTheme? = nil,
        backgroundHex: String? = nil,
        sampleRect: CGRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    ) -> some View {
        modifier(CoverControlContrastModifier(
            coverImage: coverImage,
            fallbackGradient: fallbackGradient,
            backgroundHex: backgroundHex,
            sampleRect: sampleRect
        ))
    }
}

private enum CoverArtworkLuminance {
    private static let sampleSide = 16
    /// Luminance is immutable for a UIImage and normalized sample rect. Keeping
    /// the cache bounded prevents repeated SwiftUI updates from re-rendering
    /// the 16 × 16 crop while allowing unused artwork to be reclaimed.
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 256
        return cache
    }()

    static func relativeLuminance(of image: UIImage, in requestedRect: CGRect) -> CGFloat {
        let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let sampleRect = requestedRect.standardized.intersection(unitRect)
        guard !sampleRect.isNull, sampleRect.width > 0, sampleRect.height > 0 else { return 0 }

        let cacheKey = luminanceCacheKey(for: image, sampleRect: sampleRect)
        if let cachedLuminance = cache.object(forKey: cacheKey) {
            return CGFloat(cachedLuminance.doubleValue)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let side = CGFloat(sampleSide)
        let sampledImage = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: side, height: side))

            // Draw the complete, orientation-correct UIImage so that the
            // requested normalized crop fills the small sampling canvas.
            image.draw(in: CGRect(
                x: -sampleRect.minX * side / sampleRect.width,
                y: -sampleRect.minY * side / sampleRect.height,
                width: side / sampleRect.width,
                height: side / sampleRect.height
            ))
        }

        guard let cgImage = sampledImage.cgImage else { return 0 }
        var pixels = [UInt8](repeating: 0, count: sampleSide * sampleSide * 4)
        guard let context = CGContext(
            data: &pixels,
            width: sampleSide,
            height: sampleSide,
            bitsPerComponent: 8,
            bytesPerRow: sampleSide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var total: CGFloat = 0
        var count: CGFloat = 0
        for y in 0..<sampleSide {
            for x in 0..<sampleSide {
                // The overlay controls are circular. Ignoring the crop's
                // corners prevents pixels outside the button from skewing it.
                let dx = (CGFloat(x) + 0.5) / side - 0.5
                let dy = (CGFloat(y) + 0.5) / side - 0.5
                guard dx * dx + dy * dy <= 0.25 else { continue }

                let offset = (y * sampleSide + x) * 4
                let red = linearized(CGFloat(pixels[offset]) / 255)
                let green = linearized(CGFloat(pixels[offset + 1]) / 255)
                let blue = linearized(CGFloat(pixels[offset + 2]) / 255)
                total += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                count += 1
            }
        }
        let luminance = count > 0 ? total / count : 0
        cache.setObject(NSNumber(value: Double(luminance)), forKey: cacheKey)
        return luminance
    }

    private static func luminanceCacheKey(for image: UIImage, sampleRect: CGRect) -> NSString {
        let scale: CGFloat = 10_000
        let values = [sampleRect.minX, sampleRect.minY, sampleRect.width, sampleRect.height]
            .map { Int(($0 * scale).rounded()) }
        return "\(ObjectIdentifier(image).hashValue):\(values[0]):\(values[1]):\(values[2]):\(values[3])" as NSString
    }

    nonisolated static func relativeLuminance(ofHex hex: String) -> CGFloat? {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }

        let red = CGFloat((rgb >> 16) & 0xFF) / 255
        let green = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(rgb & 0xFF) / 255
        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    nonisolated private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
