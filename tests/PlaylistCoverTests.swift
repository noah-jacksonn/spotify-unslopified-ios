import Foundation
import CoreGraphics

@main
struct PlaylistCoverTests {
    static func main() {
        for image in [CGSize(width: 4000, height: 3000), CGSize(width: 1200, height: 4000),
                      CGSize(width: 640, height: 640), CGSize(width: 20000, height: 1000)] {
            for zoom: CGFloat in [-2, 1, 2.3, 6, 20] {
                for x: CGFloat in [-100, -0.3, 0, 0.3, 100] {
                    for y: CGFloat in [-100, -0.3, 0, 0.3, 100] {
                        let crop = PlaylistCoverCrop(zoom: zoom, x: x, y: y).constrained(imageSize: image)
                        precondition((1...6).contains(crop.zoom))
                        let preview = crop.imageRect(imageSize: image, side: 280)
                        let output = crop.imageRect(imageSize: image, side: 640)
                        precondition(preview.minX <= 0.0001 && preview.minY <= 0.0001)
                        precondition(preview.maxX >= 279.9999 && preview.maxY >= 279.9999, "No blank edges after panning or zooming out")
                        precondition(abs(preview.width / preview.height - image.width / image.height) < 0.0001, "Preserve aspect ratio")
                        precondition(abs(preview.minX / 280 - output.minX / 640) < 0.0001)
                        precondition(abs(preview.minY / 280 - output.minY / 640) < 0.0001)
                        precondition(abs(preview.width / 280 - output.width / 640) < 0.0001, "Export must match visible crop")
                    }
                }
            }
        }
        let portrait = PlaylistCoverCrop().imageRect(imageSize: CGSize(width: 100, height: 200), side: 640)
        precondition(portrait == CGRect(x: 0, y: -320, width: 640, height: 1280), "Initial crop is centered")
        print("Playlist cover crop checks passed: portrait, landscape, square, panorama, zoom limits, pan limits, aspect ratio, preview/export agreement")
    }
}
