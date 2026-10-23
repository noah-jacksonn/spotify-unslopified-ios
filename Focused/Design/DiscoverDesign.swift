import SwiftUI

/// Sleeves entry and Editorial song list, selected in the on-phone Discover segtest.
struct DiscoverEntry: View {
    var artworks: [Artwork]
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                ForEach(0..<3) { index in
                    ArtworkView(artwork: artworks.isEmpty ? .none : artworks[index % artworks.count])
                        .frame(width: 40, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(look.palette.text.opacity(0.15), lineWidth: 0.5))
                        .rotationEffect(.degrees(Double(index - 1) * 10))
                        .offset(x: CGFloat(index - 1) * 12, y: index == 1 ? -3 : 3)
                        .shadow(color: look.palette.background.opacity(0.4), radius: 5, y: 3)
                }
            }
            .frame(width: 70, height: 56)
            .accessibilityHidden(true)
            Text("Discover").font(look.font(20, .semibold)).tracking(look.titleTracking).foregroundStyle(look.palette.text)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(look.font(16, .medium)).foregroundStyle(look.palette.muted)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 20).fill(look.palette.surface)
                .overlay(alignment: .leading) {
                    Circle().fill(look.palette.accent.opacity(0.06)).frame(width: 100).blur(radius: 30).offset(x: -20)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Discover")
    }

}

struct DiscoverHeading: View {
    var isToday: Bool
    @Environment(\.look) private var look

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                    .font(look.font(11, .semibold)).tracking(1.4).foregroundStyle(look.palette.muted)
                Text(isToday ? "Your daily\nfive." : "A new day\nawaits.")
                    .font(look.display(42)).tracking(look.titleTracking - 0.4)
                    .foregroundStyle(look.palette.text).fixedSize(horizontal: false, vertical: true)
                Text("Five fresh finds.").font(look.font(16)).foregroundStyle(look.palette.muted)
            }
            Spacer(minLength: 0)
            Text("05").font(look.display(94)).tracking(-7)
                .foregroundStyle(look.palette.accent.opacity(0.17))
                .padding(.bottom, 17).accessibilityHidden(true)
        }
    }
}

/// Matches the controls and five editorial rows without exposing yesterday's songs.
struct DiscoverSkeleton: View {
    @Environment(\.look) private var look

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Capsule().frame(width: 132, height: 46)
                Circle().frame(width: 46, height: 46)
                Circle().frame(width: 46, height: 46)
            }
            ForEach(0..<5) { index in
                VStack(spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        RoundedRectangle(cornerRadius: look.artRadius(70))
                            .frame(width: 70, height: 70)
                        VStack(alignment: .leading, spacing: 10) {
                            bar(width: [0.9, 0.7, 0.85, 0.65, 0.8][index], height: 16)
                            bar(width: 0.55, height: 12)
                            bar(width: 0.75, height: 10)
                        }
                        .padding(.top, 3)
                        Capsule().frame(width: 20, height: 10)
                    }
                    if index < 4 { Rectangle().frame(height: 0.5) }
                }
            }
        }
        .foregroundStyle(look.palette.muted.opacity(0.3))
        .compositingGroup()
        .modifier(DiagonalShimmer())
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading today's five")
        .accessibilityIdentifier("discover.skeleton")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        Capsule().frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .scaleEffect(x: width, anchor: .leading)
    }
}

struct DiscoverTracks: View {
    var edition: DailyEdition
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    var body: some View {
        VStack(spacing: 22) {
            ForEach(Array(edition.picks.enumerated()), id: \.element.id) { index, pick in
                editorial(pick, index: index)
            }
        }
    }

    private func play(_ index: Int) {
        model.music?.play(.tracks(edition.picks[index...].map(\.track.uri)))
    }

    private func artwork(_ pick: DailyPick) -> some View {
        ArtworkView(artwork: Artwork(url: pick.track.imageURL, seed: pick.track.demoSeed))
    }

    private func title(_ pick: DailyPick, size: CGFloat = 17) -> some View {
        let current = model.music?.nowPlaying?.trackURI == pick.track.uri
        return Text(pick.track.name).font(look.font(size, .semibold))
            .foregroundStyle(current ? look.palette.accent : look.palette.text)
            .multilineTextAlignment(.leading).lineLimit(2)
    }

    private func artist(_ pick: DailyPick) -> some View {
        Text(pick.track.artists).font(look.font(13)).foregroundStyle(look.palette.muted)
            .multilineTextAlignment(.leading).lineLimit(1)
    }

    private func source(_ pick: DailyPick) -> some View {
        NavigationLink(value: pick.artist) {
            HStack(spacing: 4) {
                Text(pick.connection.map { "Via \($0)" } ?? "Inspired by \(pick.sourcePlaylist)").lineLimit(1)
                Image(systemName: "arrow.up.right").font(look.font(9, .semibold))
            }
            .font(look.font(11)).foregroundStyle(look.palette.muted)
            .frame(minHeight: 28, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Explore \(pick.artist.name)")
    }

    private func editorial(_ pick: DailyPick, index: Int) -> some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Button { play(index) } label: {
                    artwork(pick).frame(width: 70, height: 70).clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(PressScale()).accessibilityLabel("Play \(pick.track.name)")
                VStack(alignment: .leading, spacing: 3) {
                    Button { play(index) } label: {
                        VStack(alignment: .leading, spacing: 5) { title(pick); artist(pick) }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    source(pick)
                }
                VStack(spacing: 3) {
                    Text(String(format: "%02d", index + 1)).font(look.font(11, .medium).monospacedDigit())
                        .foregroundStyle(look.palette.accent)
                    AddToPlaylistMenu(track: pick.track)
                }
            }
            if index < edition.picks.count - 1 { Rectangle().fill(look.palette.line.opacity(0.5)).frame(height: 0.5) }
        }
        .queueOnSwipe(pick.track)
        .songContextMenu(pick.track, play: { play(index) })
    }

}
