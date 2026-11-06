import SwiftUI

struct SleepTimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var timer: SleepTimerService
    @State private var customMinutes = ""
    private let options = [5, 10, 15, 30, 45, 60]
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            Text("Sleep Timer").font(.title2.bold()).foregroundStyle(AppColors.textPrimary)
            Text(timer.isActive ? "Stops in \(format(timer.remaining))" : "Stop music after...").font(.subheadline).foregroundStyle(AppColors.textSecondary)
            if timer.isActive, let deadline = timer.deadline { Text("Stops at \(deadline.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(AppColors.textTertiary) }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AppSpacing.sm) {
                ForEach(options, id: \.self) { minutes in Button("\(minutes) min") { timer.start(minutes: minutes); dismiss() }.buttonStyle(.bordered).tint(AppColors.accentPrimary).frame(minHeight: 44) }
            }
            HStack { TextField("Custom minutes", text: $customMinutes).keyboardType(.numberPad).textFieldStyle(.roundedBorder); Button("Set") { if let minutes = Int(customMinutes), minutes >= 1 { timer.start(minutes: minutes); dismiss() } }.buttonStyle(.borderedProminent).tint(AppColors.accentPrimary) }
            HStack(spacing: AppSpacing.sm) { if timer.isActive { Button("Reset Timer") { timer.reset() }.buttonStyle(.bordered); Button("Cancel Timer") { timer.cancel(); dismiss() }.buttonStyle(.bordered).tint(AppColors.error) }; Button("Done") { dismiss() }.buttonStyle(.bordered) }
        }.padding(AppSpacing.xl).frame(maxWidth: .infinity).background(AppColors.backgroundPrimary).preferredColorScheme(.dark).accessibilityIdentifier("sleep-timer-sheet")
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}

struct SleepTimerStatusIndicator: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var timer: SleepTimerService
    var showsLabel = false
    var onTap: () -> Void
    var body: some View {
        if timer.isActive {
            if scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in control }
            } else { control }
        }
    }
    private var control: some View {
        Button(action: onTap) {
            Label(showsLabel ? "Sleep Timer · \(format(timer.remaining))" : format(timer.remaining), systemImage: "moon.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(AppColors.accentPrimary)
                .padding(.horizontal, AppSpacing.sm).padding(.vertical, 6)
                .background(AppColors.backgroundSecondary, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("sleep-timer-indicator")
    }
    private func format(_ seconds: TimeInterval) -> String { String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
}
