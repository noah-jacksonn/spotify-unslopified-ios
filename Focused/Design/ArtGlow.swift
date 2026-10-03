import SwiftUI
import UIKit

/// The page glow takes its color from the current song's art (Noah,
/// 2026-10-03). This finds the art's most vivid color; `Look` turns it into
/// a glow that suits the theme.
enum ArtGlow {
    /// nil when the art is grey or blank, so the page keeps the accent glow.
    static func tint(for artwork: Artwork) async -> UIColor? {
        switch artwork {
        case .seed(let seed):
            return UIColor(GeneratedCover.colors(seed)[1])
        case .url, .image:
            guard let image = await ImageCache.shared.image(for: artwork) else { return nil }
            return await Task.detached(priority: .utility) { ArtGlow.vivid(in: image) }.value
        case .none:
            return nil
        }
    }

    /// Shrinks the art to 16×16, sorts the pixels into hue buckets weighted
    /// by how colorful they are, and averages the heaviest bucket. A plain
    /// average of the whole cover comes out a muddy brown.
    private static func vivid(in image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let bucketCount = 12
        var weights = [CGFloat](repeating: 0, count: bucketCount)
        var sums = [(r: CGFloat, g: CGFloat, b: CGFloat)](repeating: (0, 0, 0), count: bucketCount)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[i]) / 255, g = CGFloat(pixels[i + 1]) / 255, b = CGFloat(pixels[i + 2]) / 255
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.2, brightness > 0.15 else { continue }
            let weight = saturation * brightness
            let bucket = min(bucketCount - 1, Int(hue * CGFloat(bucketCount)))
            weights[bucket] += weight
            sums[bucket].r += r * weight
            sums[bucket].g += g * weight
            sums[bucket].b += b * weight
        }

        // Too little color across the cover: treat it as grey.
        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 4 else { return nil }
        let sum = sums[best], weight = weights[best]
        return UIColor(red: sum.r / weight, green: sum.g / weight, blue: sum.b / weight, alpha: 1)
    }
}
