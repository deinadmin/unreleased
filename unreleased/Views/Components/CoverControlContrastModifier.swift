import SwiftUI
import UIKit

/// Styles a control placed over cover artwork with a readable black or white tint.
///
/// The image is reduced to one pixel before measuring its relative luminance, which
/// makes this inexpensive while still reflecting the overall brightness of the cover.
struct CoverControlContrastModifier: ViewModifier {
    let coverImage: UIImage?
    let fallbackGradient: GradientTheme?

    private var usesDarkControl: Bool {
        let luminance: CGFloat
        if let coverImage {
            luminance = CoverArtworkLuminance.relativeLuminance(of: coverImage)
        } else if let fallbackGradient {
            luminance = CoverArtworkLuminance.relativeLuminance(of: fallbackGradient)
        } else {
            luminance = 0
        }
        return luminance > 0.55
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
    func coverControlContrast(
        for coverImage: UIImage?,
        fallbackGradient: GradientTheme? = nil
    ) -> some View {
        modifier(CoverControlContrastModifier(
            coverImage: coverImage,
            fallbackGradient: fallbackGradient
        ))
    }
}

private enum CoverArtworkLuminance {
    static func relativeLuminance(of image: UIImage) -> CGFloat {
        guard let cgImage = image.cgImage else { return 0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0 else { return 0 }
        let red = CGFloat(pixel[0]) / 255 / alpha
        let green = CGFloat(pixel[1]) / 255 / alpha
        let blue = CGFloat(pixel[2]) / 255 / alpha
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    static func relativeLuminance(of gradient: GradientTheme) -> CGFloat {
        let luminances = gradient.colors.compactMap(relativeLuminance(ofHex:))
        guard !luminances.isEmpty else { return 0 }
        return luminances.reduce(0, +) / CGFloat(luminances.count)
    }

    private static func relativeLuminance(ofHex hex: String) -> CGFloat? {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }

        let red = CGFloat((rgb >> 16) & 0xFF) / 255
        let green = CGFloat((rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(rgb & 0xFF) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
