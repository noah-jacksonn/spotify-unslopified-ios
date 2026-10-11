import SwiftUI

/// The app's three-bar mark. With `playing`, the bars move like a level
/// meter; it doubles as the "now playing" indicator.
struct BarsMark: View {
    var color: Color
    var size: CGFloat = 18
    var playing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: size * 0.11) {
                ForEach(0..<3, id: \.self) { i in
                    let rest: CGFloat = i == 1 ? 1 : 0.64
                    let wave = playing ? 0.55 + 0.45 * abs(sin(t * (2.2 + Double(i) * 0.9) + Double(i))) : 1
                    Capsule().fill(color)
                        .frame(width: size * 0.18, height: size * rest * wave)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }
}

/// The app's loader: its three bars, moving. Muted and small by default,
/// and it waits `delay` before fading in, so a quick load shows nothing
/// (Noah, 2026-10-03: subtle, and used everywhere instead of spinners).
struct BarsLoader: View {
    var size: CGFloat = 22
    var color: Color?
    var delay: Duration = .milliseconds(400)
    @Environment(\.look) private var look
    @State private var visible = false

    var body: some View {
        BarsMark(color: color ?? look.palette.muted.opacity(0.6), size: size, playing: visible)
            .opacity(visible ? 1 : 0)
            .animation(look.animation, value: visible)
            .task {
                if delay > .zero { try? await Task.sleep(for: delay) }
                visible = true
            }
            .accessibilityElement()
            .accessibilityLabel("Loading")
    }
}

struct CircleIconButton: View {
    var systemName: String
    var label: String
    var size: CGFloat = 46
    var action: () -> Void
    @Environment(\.look) private var look

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(look.palette.text)
                .frame(width: size, height: size)
                .surface(look, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// The accent "Play" capsule used on playlist pages and the shelf.
struct PlayPill: View {
    var title = "Play"
    var systemName = "play.fill"
    var action: () -> Void
    @Environment(\.look) private var look

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(look.font(16, .semibold))
                .foregroundStyle(look.palette.onAccent)
                .padding(.horizontal, 22)
                .frame(height: 46)
                .background(look.palette.accent, in: Capsule())
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    var text: String
    @Environment(\.look) private var look

    var body: some View {
        Text(text)
            .font(look.font(13, .semibold))
            .tracking(0.3)
            .foregroundStyle(look.palette.muted)
    }
}

/// A song row: small art (or its number), name, artists, the playing
/// indicator when it's the current song, and an options menu for queue and
/// playlist additions.
struct TrackRow: View {
    var track: Track
    /// Album pages show the track number in place of (identical) artwork.
    var showsNumber = false
    var showsAddMenu = true
    var swipeToQueue = true
    var onRemove: (() -> Void)? = nil
    var action: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look

    private var isCurrent: Bool { model.music?.nowPlaying?.trackURI == track.uri }
    private var isPlaying: Bool { isCurrent && model.music?.nowPlaying?.isPaused == false }

    var body: some View {
        HStack(spacing: 4) {
            row
            if showsAddMenu { AddToPlaylistMenu(track: track) }
        }
        .queueOnSwipe(track, enabled: swipeToQueue)
        .songContextMenu(track, play: action, remove: onRemove)
    }

    private var row: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if showsNumber {
                    Text(track.number.map(String.init) ?? "")
                        .font(look.font(15, .medium).monospacedDigit())
                        .foregroundStyle(isCurrent ? look.palette.accent : look.palette.muted)
                        .frame(width: 26, alignment: .center)
                } else {
                    ArtworkView(artwork: Artwork(url: track.imageURL, seed: track.demoSeed))
                        .frame(width: 46, height: 46)
                        .artClip(look, size: 46)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(look.font(16, .medium))
                        .foregroundStyle(isCurrent ? look.palette.accent : look.palette.text)
                        .lineLimit(1)
                    Text(track.artists)
                        .font(look.font(13))
                        .foregroundStyle(look.palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    BarsMark(color: look.palette.accent, size: 16, playing: isPlaying)
                } else {
                    Text(Self.duration(track.durationMs))
                        .font(look.font(12).monospacedDigit())
                        .foregroundStyle(look.palette.muted)
                }
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func duration(_ ms: Int) -> String {
        let seconds = ms / 1000
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// Draggable progress bar with times underneath.
struct Scrubber: View {
    var state: NowPlaying
    var onSeek: (Int) -> Void
    @Environment(\.look) private var look
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: state.isPaused)) { timeline in
            let fraction = dragFraction ?? state.progress(at: timeline.date)
            VStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(look.palette.text.opacity(0.16))
                        Capsule().fill(look.palette.text).frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: dragFraction == nil ? 4 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = min(1, max(0, $0.location.x / geo.size.width)) }
                            .onEnded { _ in
                                if let dragFraction { onSeek(Int(dragFraction * Double(state.durationMs))) }
                                dragFraction = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
                }
                .frame(height: 20)
                HStack {
                    Text(TrackRow.duration(Int(fraction * Double(state.durationMs))))
                    Spacer()
                    Text("-" + TrackRow.duration(max(0, state.durationMs - Int(fraction * Double(state.durationMs)))))
                }
                .font(look.font(12).monospacedDigit())
                .foregroundStyle(look.palette.muted)
            }
        }
    }
}

struct TransportControls: View {
    var state: NowPlaying
    var music: any MusicService
    @Environment(\.look) private var look

    var body: some View {
        HStack(spacing: 40) {
            button("backward.fill", "Previous") { music.previous() }
            Button { music.togglePause() } label: {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(look.palette.onAccent)
                    .frame(width: 68, height: 68)
                    .background(look.palette.accent, in: Circle())
            }
            .buttonStyle(PressScale())
            .accessibilityLabel(state.isPaused ? "Play" : "Pause")
            button("forward.fill", "Next") { music.next() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: state.isPaused)
    }

    private func button(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(look.palette.text)
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Play (or Resume/Pause while this context is playing) and Shuffle, for a
/// playlist or album page.
struct ContextPlayControls: View {
    var contextURI: String
    var tracks: [Track]
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.music?.nowPlaying
        HStack(spacing: 12) {
            if state?.contextURI == contextURI, let state {
                PlayPill(title: state.isPaused ? "Resume" : "Pause", systemName: state.isPaused ? "play.fill" : "pause.fill") {
                    model.music?.togglePause()
                }
            } else {
                PlayPill { model.music?.play(.context(uri: contextURI)) }
            }
            if !tracks.isEmpty {
                CircleIconButton(systemName: "text.badge.plus", label: "Add all songs to queue") {
                    model.enqueue(tracks)
                }
                CircleIconButton(systemName: "shuffle", label: "Shuffle") {
                    if let random = tracks.randomElement() {
                        model.music?.shuffle(.context(uri: contextURI, startAt: random.uri, position: random.position))
                    }
                }
            }
        }
    }
}
