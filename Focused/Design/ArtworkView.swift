import SwiftUI
import UIKit

/// Square artwork from any `Artwork` source, filling its frame. Shape and
/// clipping are the caller's job (`artClip`).
struct ArtworkView: View {
    var artwork: Artwork
    @Environment(\.look) private var look
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            switch artwork {
            case .seed(let seed):
                GeneratedCover(seed: seed)
            case .none:
                Rectangle().fill(look.palette.raised)
                    .overlay(Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(look.palette.muted))
            case .url, .image:
                Rectangle().fill(look.palette.raised)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
        }
        .task(id: key) {
            // Clear first so the previous cover doesn't sit beside a new
            // title, and drop a result that arrives after the art changed.
            image = nil
            let loaded = await ImageCache.shared.image(for: artwork)
            if !Task.isCancelled { image = loaded }
        }
    }

    private var key: String {
        switch artwork {
        case .url(let url): url.absoluteString
        case .image(let id): id
        default: ""
        }
    }
}

extension View {
    /// Clips to the current art shape at this size.
    func artClip(_ look: Look, size: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: look.artRadius(size), style: .continuous))
    }
}

/// Decoded artwork, keyed by URL or App Remote image id. Downloads of the
/// same URL share one request, images are decoded off the main thread, and
/// the cache is capped by decoded size.
final class ImageCache {
    static let shared = ImageCache()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    func image(for artwork: Artwork) async -> UIImage? {
        switch artwork {
        case .url(let url):
            if let cached = cache.object(forKey: url.absoluteString as NSString) { return cached }
            if let task = inFlight[url] { return await task.value }
            let task = Task<UIImage?, Never> {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = await UIImage(data: data)?.byPreparingForDisplay() else { return nil }
                return image
            }
            inFlight[url] = task
            let image = await task.value
            inFlight[url] = nil
            if let image { store(image, key: url.absoluteString) }
            return image
        case .image(let id):
            return cache.object(forKey: id as NSString)
        default:
            return nil
        }
    }

    func contains(id: String) -> Bool { cache.object(forKey: id as NSString) != nil }

    func store(_ image: UIImage, id: String) { store(image, key: id) }

    private func store(_ image: UIImage, key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels) * 4)
    }
}

/// Preview-mode album art: a seeded mesh gradient with one of a few
/// graphic motifs, so every sample cover is distinct but stable.
struct GeneratedCover: View {
    var seed: Int

    var body: some View {
        let colors = Self.colors(seed)
        ZStack {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [Float(0.3 + Double(seed % 5) * 0.1), Float(0.35 + Double(seed % 3) * 0.12)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [colors[0], colors[1], colors[2], colors[1], colors[3], colors[0], colors[2], colors[0], colors[1]]
            )
            GeometryReader { geo in
                let s = geo.size.width
                motif(size: s, colors: colors)
            }
        }
    }

    @ViewBuilder
    private func motif(size s: CGFloat, colors: [Color]) -> some View {
        switch seed % 6 {
        case 0:
            Circle().fill(colors[3].opacity(0.9)).frame(width: s * 0.46).position(x: s * 0.62, y: s * 0.42)
        case 1:
            VStack(spacing: s * 0.05) {
                ForEach(0..<6, id: \.self) { _ in Rectangle().fill(.white.opacity(0.18)).frame(height: s * 0.035) }
            }
            .frame(width: s, height: s).rotationEffect(.degrees(-18)).clipped()
        case 2:
            Circle().stroke(.white.opacity(0.35), lineWidth: s * 0.02).frame(width: s * 0.7)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: s * 0.02).frame(width: s * 0.42))
                .position(x: s / 2, y: s / 2)
        case 3:
            RoundedRectangle(cornerRadius: s * 0.04).fill(.black.opacity(0.22))
                .frame(width: s * 0.5, height: s * 0.5).rotationEffect(.degrees(12)).position(x: s * 0.4, y: s * 0.58)
        case 4:
            Path { path in
                for i in 0..<5 {
                    let y = s * (0.25 + CGFloat(i) * 0.12)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addCurve(to: CGPoint(x: s, y: y), control1: CGPoint(x: s * 0.33, y: y - s * 0.12), control2: CGPoint(x: s * 0.66, y: y + s * 0.12))
                }
            }
            .stroke(.white.opacity(0.3), lineWidth: s * 0.012)
        default:
            Capsule().fill(colors[3].opacity(0.85)).frame(width: s * 0.16, height: s * 0.6).position(x: s * 0.3, y: s * 0.5)
            Capsule().fill(.white.opacity(0.3)).frame(width: s * 0.16, height: s * 0.38).position(x: s * 0.55, y: s * 0.62)
        }
    }

    /// Golden-angle hue steps keep neighboring seeds far apart; the four
    /// colors stay analogous so covers read as one mood, not a rainbow.
    static func colors(_ seed: Int) -> [Color] {
        let base = (Double(seed) * 0.381966).truncatingRemainder(dividingBy: 1)
        func hue(_ offset: Double, _ s: Double, _ b: Double) -> Color {
            Color(hue: (base + offset + 1).truncatingRemainder(dividingBy: 1), saturation: s, brightness: b)
        }
        let deep = seed.isMultiple(of: 3)
        return [hue(0, 0.62, deep ? 0.32 : 0.55), hue(0.05, 0.5, deep ? 0.55 : 0.82),
                hue(-0.06, 0.7, deep ? 0.18 : 0.38), hue(0.12, 0.35, 0.96)]
    }
}
