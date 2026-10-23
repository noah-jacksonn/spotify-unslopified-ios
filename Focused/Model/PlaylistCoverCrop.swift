import Foundation
import CoreGraphics

/// Coordinates are fractions of the square viewport, independent of display
/// size. The same rect drives both the gesture preview and the exported JPEG.
nonisolated struct PlaylistCoverCrop: Equatable, Sendable {
    var zoom: CGFloat = 1
    var x: CGFloat = 0
    var y: CGFloat = 0

    func constrained(imageSize: CGSize) -> Self {
        let zoom = min(6, max(1, zoom))
        let shortest = max(1, min(imageSize.width, imageSize.height))
        let width = imageSize.width / shortest * zoom
        let height = imageSize.height / shortest * zoom
        let limitX = max(0, (width - 1) / 2)
        let limitY = max(0, (height - 1) / 2)
        return Self(zoom: zoom, x: min(limitX, max(-limitX, x)), y: min(limitY, max(-limitY, y)))
    }

    func imageRect(imageSize: CGSize, side: CGFloat) -> CGRect {
        let crop = constrained(imageSize: imageSize)
        let factor = side / max(1, min(imageSize.width, imageSize.height)) * crop.zoom
        let size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
        return CGRect(x: (side - size.width) / 2 + crop.x * side,
                      y: (side - size.height) / 2 + crop.y * side,
                      width: size.width, height: size.height)
    }
}
