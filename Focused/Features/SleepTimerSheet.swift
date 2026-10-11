import SwiftUI

/// The sleep timer (Noah, 2026-10-03: "any minutes"): hour and minute
/// wheels like the Clock app's timer, with a few shortcuts; once it's
/// running, the time left, +15 min and Cancel. Opened by long-pressing
/// Home's bars or from the … menu.
struct SleepTimerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.look) private var look
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sleep.lastMinutes") private var lastMinutes = 30
    @State private var hours = 0
    @State private var minutes = 30

    private var total: Int { hours * 60 + minutes }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Sleep timer", systemImage: "moon.zzz.fill")
                    .font(look.display(26))
                    .tracking(look.titleTracking)
                    .foregroundStyle(look.palette.text)
                Text("Spotify pauses when it ends.")
                    .font(look.font(15))
                    .foregroundStyle(look.palette.muted)
            }
            if let endsAt = model.sleepTimer.endsAt {
                running(endsAt)
                    .transition(.opacity)
            } else {
                chooser
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(look.animation, value: model.sleepTimer.endsAt == nil)
        .presentationDetents([.height(470)])
        .presentationDragIndicator(.visible)
        .presentationBackground(look.palette.background)
        .onAppear {
            hours = lastMinutes / 60
            minutes = lastMinutes % 60
        }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                ForEach([15, 30, 45, 60], id: \.self) { preset in
                    let chosen = preset == total
                    Button {
                        hours = preset / 60
                        minutes = preset % 60
                    } label: {
                        Text(preset == 60 ? "1 hr" : "\(preset) min")
                            .font(look.font(15, .medium))
                            .foregroundStyle(chosen ? look.palette.onAccent : look.palette.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(chosen ? look.palette.accent : look.palette.surface, in: Capsule())
                    }
                    .buttonStyle(PressScale())
                }
            }
            HStack(spacing: 0) {
                Picker("Hours", selection: $hours) {
                    ForEach(0..<24, id: \.self) { Text("\($0) hr").tag($0) }
                }
                Picker("Minutes", selection: $minutes) {
                    ForEach(0..<60, id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            .pickerStyle(.wheel)
            .font(look.font(20, .medium))
            .frame(height: 150)
            .sensoryFeedback(.selection, trigger: total)
            PlayPill(title: "Start", systemName: "moon.fill") {
                lastMinutes = total
                model.sleepTimer.start(minutes: total)
                dismiss()
            }
            .disabled(total == 0)
            .opacity(total == 0 ? 0.4 : 1)
        }
    }

    // MARK: Running

    private func running(_ endsAt: Date) -> some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(endsAt.timeIntervalSince(context.date)))
                    .font(look.display(64).monospacedDigit())
                    .tracking(look.titleTracking)
                    .foregroundStyle(look.palette.text)
                    .contentTransition(.numericText(countsDown: true))
            }
            Text("Pauses at \(endsAt.formatted(date: .omitted, time: .shortened))")
                .font(look.font(15))
                .foregroundStyle(look.palette.muted)
            HStack(spacing: 12) {
                Button { model.sleepTimer.extend(minutes: 15) } label: {
                    Label("15 min", systemImage: "plus")
                        .font(look.font(16, .semibold))
                        .foregroundStyle(look.palette.text)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .surface(look, in: Capsule())
                }
                .buttonStyle(PressScale())
                PlayPill(title: "Cancel timer", systemName: "xmark") { model.sleepTimer.cancel() }
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    /// 1:05:09, or 4:09 under an hour.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// For the Home badge: "1 hr 20 min", "23 min", "<1 min".
    static func short(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if interval < 60 { return "<1 min" }
        return minutes >= 60 ? "\(minutes / 60) hr" + (minutes % 60 > 0 ? " \(minutes % 60) min" : "") : "\(minutes) min"
    }
}
