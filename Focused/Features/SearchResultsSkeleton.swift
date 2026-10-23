import SwiftUI

/// Holds the shape of song results while a new search is in flight.
struct SearchResultsSkeleton: View {
    var showsLyrics: Bool
    var rowCount = 5
    var showsHeading = true
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: showsLyrics ? 16 : 6) {
            if showsHeading {
                Capsule()
                    .frame(width: showsLyrics ? 112 : 52, height: 12)
                    .padding(.vertical, 3)
            }

            ForEach(0..<rowCount, id: \.self) { row in
                let index = row % 5
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: look.artRadius(46), style: .continuous)
                            .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 8) {
                            bar(width: [0.84, 0.97, 0.65, 0.76, 0.9][index], height: 14)
                            bar(width: [0.55, 0.42, 0.67, 0.48, 0.6][index], height: 10)
                        }
                        Capsule().frame(width: 26, height: 10)
                        Circle().frame(width: 26, height: 26)
                            .frame(width: 40, height: 44)
                    }
                    .padding(.vertical, 7)

                    if showsLyrics {
                        VStack(alignment: .leading, spacing: 6) {
                            bar(width: 1, height: 10)
                            bar(width: [0.72, 0.9, 0.62, 0.8, 0.68][index], height: 10)
                        }
                        .padding(.top, 2)
                        .padding(.leading, 58)
                        .padding(.trailing, 44)
                        .padding(.bottom, 5)
                    }
                }
            }
        }
        .foregroundStyle(look.palette.muted.opacity(0.3))
        // One mask spans every row, so the shine travels down the whole list.
        .compositingGroup()
        .modifier(DiagonalShimmer())
        .padding(.horizontal, look.margin)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsLyrics ? "Searching lyrics" : "Searching")
        .accessibilityIdentifier("search.skeleton")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: width, anchor: .leading)
    }
}
