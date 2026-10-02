import SwiftUI

/// An artist: their photo under a big name, Play, ten popular songs, then
/// albums and singles. Laid out like Spotify's artist page, minus the
/// recommendations.
struct ArtistView: View {
    var artist: CatalogItem
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @State private var page: ArtistPage?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: look.gap * 1.4) {
                hero
                PlayPill { model.music?.play(.context(uri: artist.uri)) }
                    .padding(.horizontal, look.margin)
                if let page {
                    if !page.popular.isEmpty { popular(page.popular) }
                    if !page.albums.isEmpty { ReleaseShelf(title: "Albums", releases: page.albums) }
                    if !page.singles.isEmpty { ReleaseShelf(title: "Singles & EPs", releases: page.singles) }
                } else if let error {
                    Text(error).font(look.font(15)).foregroundStyle(look.palette.muted).padding(.horizontal, look.margin)
                } else {
                    ProgressView().tint(look.palette.muted).frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .pageBackground()
        .task { await load() }
    }

    /// The photo bleeds off the top and fades into the page, the name over
    /// its lower edge, like the full player's poster.
    private var hero: some View {
        let shown = page?.artist ?? artist
        return Color.clear
            .frame(height: 380)
            .overlay {
                ArtworkView(artwork: Artwork(url: shown.imageURL, seed: shown.demoSeed))
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(shown.name)
                    .font(look.display(48))
                    .tracking(look.titleTracking - 0.6)
                    .foregroundStyle(look.palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, look.margin)
            }
    }

    private func popular(_ tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Popular")
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, showsAddMenu: true) {
                    // Play from this song on through the rest of the list.
                    model.music?.play(.tracks(tracks[index...].map(\.uri)))
                }
            }
        }
        .padding(.horizontal, look.margin)
    }

    private func load() async {
        guard page == nil, let music = model.music else { return }
        do {
            page = try await music.artistPage(artist)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A sideways row of covers that open their page: albums, or round artist
/// photos (`circle`).
struct ReleaseShelf: View {
    var title: String
    var releases: [CatalogItem]
    var size: CGFloat = 140
    var circle = false
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: title).padding(.horizontal, look.margin)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(releases) { release in
                        NavigationLink(value: release) {
                            VStack(alignment: circle ? .center : .leading, spacing: 8) {
                                ArtworkView(artwork: Artwork(url: release.imageURL, seed: release.demoSeed))
                                    .frame(width: size, height: size)
                                    .clipShape(RoundedRectangle(cornerRadius: circle ? size / 2 : look.artRadius(size), style: .continuous))
                                Text(release.name)
                                    .font(look.font(14, .medium))
                                    .foregroundStyle(look.palette.text)
                                    .lineLimit(1)
                                if !circle {
                                    Text(release.subtitle)
                                        .font(look.font(12))
                                        .foregroundStyle(look.palette.muted)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: size, alignment: circle ? .center : .leading)
                        }
                        .buttonStyle(PressScale())
                    }
                }
            }
            .contentMargins(.horizontal, look.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }
}
