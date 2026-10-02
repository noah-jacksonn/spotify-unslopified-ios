#if DEBUG
import SwiftUI
import UIKit

/// Debug-only segtest scaffold, adapted from harmony-ios (Noah 2026-09-17). A segtest is a temporary
/// in-place comparison: fill in one `SegtestRow` per adjustable property and
/// the panel supplies the rest — a small dot that toggles the rows, floating
/// above the page so nothing reflows, draggable to wherever it stays out of
/// the feature's way (position remembered per `id` across launches).
///
///     @State private var test = WaveTest()
///     ...
///     screen
///         .segtest(id: "wave", corner: .bottomTrailing) {
///             SegtestRow("Stroke", $test.stroke)
///             SegtestRow("Opacity", $test.opacity)
///         }
///
/// Row options are `CaseIterable & RawRepresentable` enums whose String raw
/// values are the segment labels. Apply the modifier to the screen (or any
/// container tall enough to host the panel), not to the feature itself.
/// Delete the enum, the state, and the modifier once Noah picks.
extension View {
    func segtest<Rows: View>(
        id: String = "default",
        corner: Alignment = .bottomTrailing,
        @ViewBuilder rows: @escaping () -> Rows
    ) -> some View {
        modifier(SegtestPresenter(id: id, corner: corner, rows: rows))
    }
}

/// Puts the panel in its own `UIWindow` above everything the app draws.
/// An `.overlay` can only reach the top of the screen it is attached to, so
/// the dot ended up behind the tab bar, bottom cards, toasts and the session
/// stage (Noah 2026-09-17: it must always be in front). A window above
/// `.alert` is the only layer that beats all of them, including sheets.
///
/// The window is torn down with the view and hidden while the host screen is
/// off — otherwise the panel would keep floating over the other tabs.
private struct SegtestPresenter<Rows: View>: ViewModifier {
    var id: String
    var corner: Alignment
    @ViewBuilder var rows: () -> Rows

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .background {
                SegtestWindowInstaller(id: id, corner: corner, isVisible: isVisible, rows: rows)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
    }
}

private struct SegtestWindowInstaller<Rows: View>: UIViewRepresentable {
    var id: String
    var corner: Alignment
    var isVisible: Bool
    @ViewBuilder var rows: () -> Rows

    func makeCoordinator() -> SegtestWindowCoordinator { SegtestWindowCoordinator() }

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView(frame: .zero)
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    /// Re-pushing `rootView` on every update is what keeps rows bound to the
    /// host screen's own `@State` live across the window boundary.
    func updateUIView(_ uiView: UIView, context: Context) {
        let content = AnyView(
            DebugSegtestPanel(
                id: id,
                corner: corner,
                regions: context.coordinator.regions,
                rows: rows
            )
        )
        let visible = isVisible
        let id = id
        DispatchQueue.main.async {
            context.coordinator.sync(id: id, anchor: uiView, content: content, visible: visible)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: SegtestWindowCoordinator) {
        coordinator.teardown()
    }
}

final class SegtestWindowCoordinator {
    let regions = SegtestHitRegions()
    private var window: SegtestPassthroughWindow?
    private var host: UIHostingController<AnyView>?

    /// Which panel is on screen for each id. Two screens can carry the same
    /// test (the session screen and the reflection page it pushes), and a
    /// covered screen isn't always told it disappeared — two stacked panels
    /// then meant the dot hid only the top one and the other stayed up
    /// (Noah 2026-09-26). Each id keeps a stack of its visible panels and
    /// shows only the one that appeared last; when that one goes, the one
    /// beneath comes back. Order changes only on an appearance, never on a
    /// re-render, so a covered screen that keeps updating stays covered.
    private static var stacks: [String: [WeakCoordinator]] = [:]
    private struct WeakCoordinator { weak var value: SegtestWindowCoordinator? }
    private var wasVisible = false
    private var id: String?

    func sync(id: String, anchor: UIView, content: AnyView, visible: Bool) {
        self.id = id
        let appeared = visible && !wasVisible
        wasVisible = visible
        var stack = Self.stacks[id, default: []].filter { $0.value != nil }
        let listed = stack.contains { $0.value === self }
        if !visible || appeared || !listed {
            stack.removeAll { $0.value === self }
            if visible { stack.append(WeakCoordinator(value: self)) }
        }
        Self.stacks[id] = stack

        if visible, let scene = anchor.window?.windowScene ?? Self.activeScene() {
            if let host, let window {
                host.rootView = content
                window.overrideUserInterfaceStyle = Self.style(matching: anchor)
            } else {
                let controller = UIHostingController(rootView: content)
                controller.view.backgroundColor = .clear
                let newWindow = SegtestPassthroughWindow(windowScene: scene)
                newWindow.regions = regions
                newWindow.rootViewController = controller
                newWindow.backgroundColor = .clear
                // Above .alert so sheets, the tab bar and the toast host can't cover it.
                newWindow.windowLevel = .alert + 1
                newWindow.overrideUserInterfaceStyle = Self.style(matching: anchor)
                // Never made key: the app keeps first responder and the keyboard.
                host = controller
                window = newWindow
            }
        }
        Self.showTop(of: id)
        if !visible { window?.isHidden = true }
    }

    private static func showTop(of id: String) {
        let stack = stacks[id, default: []].compactMap(\.value)
        for coordinator in stack {
            coordinator.window?.isHidden = coordinator !== stack.last
        }
    }

    func teardown() {
        window?.isHidden = true
        window = nil
        host = nil
        if let id {
            Self.stacks[id]?.removeAll { $0.value === self || $0.value == nil }
            Self.showTop(of: id)
        }
    }

    /// RootView forces light/dark by walking the scene's windows, but it only
    /// does so when `appearanceOverride` changes — a window created later has
    /// to copy the current style itself or the panel ignores the override.
    private static func style(matching anchor: UIView) -> UIUserInterfaceStyle {
        anchor.window?.overrideUserInterfaceStyle
            ?? activeScene()?.windows.first?.overrideUserInterfaceStyle
            ?? .unspecified
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// The window covers the screen, so every touch outside the dot and the rows
/// has to fall through to the app underneath. SwiftUI hands the whole hosting
/// view back from `hitTest`, so the panel reports its own frames instead.
final class SegtestPassthroughWindow: UIWindow {
    var regions: SegtestHitRegions?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let regions, regions.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

/// Window-space frames of the panel's interactive parts.
final class SegtestHitRegions {
    private var rects: [String: CGRect] = [:]

    func set(_ rect: CGRect?, for key: String) { rects[key] = rect }

    func contains(_ point: CGPoint) -> Bool {
        rects.values.contains { $0.insetBy(dx: -6, dy: -6).contains(point) }
    }
}

private struct ReportsSegtestHitRegion: ViewModifier {
    var key: String
    var regions: SegtestHitRegions

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                // .global is the hosting window's space, which is what
                // UIWindow.hitTest is given.
                let frame = proxy.frame(in: .global)
                Color.clear
                    .onAppear { regions.set(frame, for: key) }
                    .onChange(of: frame) { _, new in regions.set(new, for: key) }
                    .onDisappear { regions.set(nil, for: key) }
            }
        }
    }
}

private extension View {
    func reportsSegtestHitRegion(_ key: String, to regions: SegtestHitRegions) -> some View {
        modifier(ReportsSegtestHitRegion(key: key, regions: regions))
    }
}

/// The panel hands its `id` to its rows so each row can save its pick.
private struct SegtestIDKey: EnvironmentKey {
    static let defaultValue = "default"
}

extension EnvironmentValues {
    fileprivate var segtestID: String {
        get { self[SegtestIDKey.self] }
        set { self[SegtestIDKey.self] = newValue }
    }
}

/// One labeled row of options. Many rows have five or more options, so
/// the segments are chips that scroll sideways rather than a fixed control.
///
/// Every pick is saved to UserDefaults as `segtest.pick.<id>.<title>` =
/// the segment label, and restored when the row appears (Noah 2026-09-23):
/// picks survive reinstalls, and `scripts/read-segtest.sh` reads them off
/// the phone so Noah never has to report what he left selected. A saved
/// label that no longer matches an option is ignored.
struct SegtestRow<Option>: View
where Option: Hashable & CaseIterable & RawRepresentable, Option.RawValue == String {
    var title: String
    @Binding var selection: Option
    @Environment(\.segtestID) private var segtestID

    init(_ title: String, _ selection: Binding<Option>) {
        self.title = title
        _selection = selection
    }

    private var storageKey: String { "segtest.pick.\(segtestID).\(title)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Color(.secondaryLabel))
            SegtestChips(options: Array(Option.allCases), selection: $selection)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: SegtestRowHeightKey.self, value: proxy.size.height)
            }
        }
        .onAppear {
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: storageKey), let option = Option(rawValue: saved) {
                if option != selection { selection = option }
            } else {
                defaults.set(selection.rawValue, forKey: storageKey)
            }
        }
        .onChange(of: selection) { _, new in
            UserDefaults.standard.set(new.rawValue, forKey: storageKey)
        }
    }
}

private struct SegtestChips<Option>: View
where Option: Hashable & RawRepresentable, Option.RawValue == String {
    var options: [Option]
    @Binding var selection: Option

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color(.systemBackground) : Color(.label))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(Capsule().fill(selected ? Color(.label) : Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Rows that tune the same thing, under one heading with the rows indented
/// beneath it, so it's clear what each row changes (Noah 2026-09-30: "I
/// don't know what is connected to what"). Name the group for the thing
/// ("Player") and its rows for the property ("Blur").
struct SegtestGroup<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(.label))
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.leading, 14)
        }
        .padding(.top, 4)
    }
}

/// The tallest row, so the panel can open sized to its first few rows.
private struct SegtestRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct DebugSegtestPanel<Rows: View>: View {
    var id: String
    var corner: Alignment
    var regions: SegtestHitRegions
    @ViewBuilder var rows: () -> Rows

    @State private var showsRows = true
    @State private var dragOrigin: CGPoint?
    @State private var panelSize: CGSize = .zero
    @State private var rowsHeight: CGFloat = 0
    @State private var rowHeight: CGFloat = 0
    @State private var resizeOrigin: CGFloat?
    /// "x,y" of the dot's center; empty until first dragged.
    @AppStorage private var storedDot: String
    /// Height the rows were resized to with the top handle: 0 = never
    /// resized (opens at `defaultRowCount` rows), -1 = grown to full height.
    @AppStorage private var storedRowsHeight: Double
    /// The app's own appearance setting (Settings → Appearance), toggled
    /// from the panel's footer. RootView applies it to every window,
    /// this one included.
    @AppStorage("appearanceOverride") private var appearanceOverride = "system"
    @Environment(\.colorScheme) private var colorScheme

    /// 18, not 24 (Noah 2026-09-23: a smaller dot); the 8 pt center stays.
    private let dotDiameter: CGFloat = 18
    private let edgeInset: CGFloat = 18
    /// Dot-to-panel gap (Noah 2026-09-23: 14 read as too far apart).
    private let panelGap: CGFloat = 6
    private let handleHeight: CGFloat = 22
    private let footerHeight: CGFloat = 38
    private let minRowsHeight: CGFloat = 56
    /// A new segtest opens showing three rows; the handle still grows it
    /// (Noah 2026-09-27: a tall test otherwise covered half the page).
    private let defaultRowCount: CGFloat = 3
    private let rowSpacing: CGFloat = 10
    private let rowsBottomPadding: CGFloat = 14

    init(
        id: String,
        corner: Alignment,
        regions: SegtestHitRegions,
        @ViewBuilder rows: @escaping () -> Rows
    ) {
        self.id = id
        self.corner = corner
        self.regions = regions
        self.rows = rows
        _storedDot = AppStorage(wrappedValue: "", "segtest.dot.\(id)")
        _storedRowsHeight = AppStorage(wrappedValue: 0, "segtest.height.\(id)")
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = geo.size
            let dot = dotCenter(in: bounds)
            ZStack(alignment: .topLeading) {
                if showsRows {
                    panel(
                        width: min(360, bounds.width - 2 * edgeInset),
                        visibleRowsHeight: visibleRowsHeight(in: bounds)
                    )
                        .position(panelCenter(for: dot, in: bounds))
                        .transition(.opacity)
                }
                dotView
                    .position(dot)
                    .gesture(dragGesture(in: bounds))
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) { showsRows.toggle() }
                    }
            }
            .coordinateSpace(name: "segtest")
        }
    }

    // MARK: Dot

    private var dotView: some View {
        ZStack {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
            Circle()
                .fill(Color(.secondaryLabel).opacity(showsRows ? 0.9 : 0.45))
                .frame(width: 8, height: 8)
        }
        .frame(width: dotDiameter, height: dotDiameter)
        .contentShape(Circle())
        .reportsSegtestHitRegion("dot", to: regions)
        .accessibilityLabel(showsRows ? "Hide design tester" : "Show design tester")
    }

    private func dotCenter(in bounds: CGSize) -> CGPoint {
        if let stored = storedPoint {
            return clamp(stored, in: bounds)
        }
        let x: CGFloat = switch corner.horizontal {
        case .leading: edgeInset + dotDiameter / 2
        case .center: bounds.width / 2
        default: bounds.width - edgeInset - dotDiameter / 2
        }
        let y: CGFloat = switch corner.vertical {
        case .top: edgeInset + dotDiameter / 2
        case .center: bounds.height / 2
        default: bounds.height - edgeInset - dotDiameter / 2
        }
        return CGPoint(x: x, y: y)
    }

    private var storedPoint: CGPoint? {
        let parts = storedDot.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    private func clamp(_ point: CGPoint, in bounds: CGSize) -> CGPoint {
        let half = dotDiameter / 2
        return CGPoint(
            x: min(max(point.x, half), max(half, bounds.width - half)),
            y: min(max(point.y, half), max(half, bounds.height - half))
        )
    }

    private func dragGesture(in bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("segtest"))
            .onChanged { value in
                let origin = dragOrigin ?? dotCenter(in: bounds)
                dragOrigin = origin
                let moved = CGPoint(
                    x: origin.x + value.translation.width,
                    y: origin.y + value.translation.height
                )
                let clamped = clamp(moved, in: bounds)
                storedDot = "\(clamped.x),\(clamped.y)"
            }
            .onEnded { _ in dragOrigin = nil }
    }

    // MARK: Panel

    /// The top handle shrinks the panel; rows past the chosen height scroll.
    private func panel(width: CGFloat, visibleRowsHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            resizeHandle(visibleRowsHeight: visibleRowsHeight)
            ScrollView {
                VStack(alignment: .leading, spacing: rowSpacing, content: rows)
                    .environment(\.segtestID, id)
                    .onPreferenceChange(SegtestRowHeightKey.self) { rowHeight = $0 }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, rowsBottomPadding)
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { rowsHeight = proxy.size.height }
                                .onChange(of: proxy.size.height) { _, height in rowsHeight = height }
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .frame(height: visibleRowsHeight)
            footer
        }
            .frame(width: width)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { panelSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in panelSize = size }
                }
            }
            .reportsSegtestHitRegion("panel", to: regions)
    }

    /// Bottom-right light/dark toggle, part of every segtest (Noah
    /// 2026-09-23). Shows the mode a tap switches TO — sun in dark, moon
    /// in light — like the welcome screen's appearance control.
    private var footer: some View {
        HStack {
            Spacer()
            Button {
                appearanceOverride = colorScheme == .dark ? "light" : "dark"
            } label: {
                Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(.label))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(.tertiarySystemFill)))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
        }
        .padding(.horizontal, 10)
        .frame(height: footerHeight, alignment: .top)
    }

    private func resizeHandle(visibleRowsHeight: CGFloat) -> some View {
        Capsule()
            .fill(Color(.secondaryLabel).opacity(0.4))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: handleHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("segtest"))
                    .onChanged { value in
                        let origin = resizeOrigin ?? visibleRowsHeight
                        resizeOrigin = origin
                        // Dragging the top edge down shrinks, up grows.
                        let proposed = max(minRowsHeight, origin - value.translation.height)
                        storedRowsHeight = proposed >= rowsHeight ? -1 : Double(proposed)
                    }
                    .onEnded { _ in resizeOrigin = nil }
            )
            .accessibilityLabel("Resize design tester")
    }

    /// Three rows until the handle resizes it (then that height, or the
    /// natural height once grown past it), capped by the room the screen
    /// leaves beside the dot.
    private func visibleRowsHeight(in bounds: CGSize) -> CGFloat {
        let room = bounds.height - 2 * edgeInset - dotDiameter - panelGap - handleHeight - footerHeight
        var height = rowsHeight > 0 ? rowsHeight : room
        if storedRowsHeight > 0 {
            height = min(height, CGFloat(storedRowsHeight))
        } else if storedRowsHeight == 0, rowHeight > 0 {
            let rows = defaultRowCount * rowHeight + (defaultRowCount - 1) * rowSpacing + rowsBottomPadding
            height = min(height, rows)
        }
        return max(minRowsHeight, min(height, room))
    }

    /// The panel grows away from the nearest vertical edge and stays inside
    /// the bounds horizontally, so dragging the dot into a corner keeps the
    /// rows on screen.
    private func panelCenter(for dot: CGPoint, in bounds: CGSize) -> CGPoint {
        let halfWidth = panelSize.width / 2
        let halfHeight = panelSize.height / 2
        let x = min(max(dot.x, halfWidth + edgeInset), max(halfWidth + edgeInset, bounds.width - halfWidth - edgeInset))
        let above = dot.y > bounds.height / 2
        let y = above
            ? dot.y - dotDiameter / 2 - panelGap - halfHeight
            : dot.y + dotDiameter / 2 + panelGap + halfHeight
        let clampedY = min(max(y, halfHeight + edgeInset), max(halfHeight + edgeInset, bounds.height - halfHeight - edgeInset))
        return CGPoint(x: x, y: clampedY)
    }
}
#endif
