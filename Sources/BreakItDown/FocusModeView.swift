import SwiftUI
import Combine

/// Shows only the next unchecked step, big, with an optional gentle timer.
struct FocusModeView: View {
    let listID: UUID
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var skipped: [UUID] = []
    @State private var celebrating = false
    @State private var timerOn = false
    @State private var remaining = 0
    @State private var running = false
    @State private var didInit = false

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var list: TaskList? { store.list(listID) }

    private var current: Step? {
        guard let list else { return nil }
        let open = list.steps.filter { !$0.done }
        return open.first { !skipped.contains($0.id) } ?? open.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(list?.title ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let list {
                    Text("\(list.doneLeaves) of \(list.totalLeaves) done")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 12)

            Spacer(minLength: 16)

            Group {
                if celebrating {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(Palette.accent)
                        Text("Done. Nice.")
                            .font(.title2)
                        Text("Take a breath. Here's the next one.")
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else if let step = current {
                    stepView(step)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(Palette.accent)
                        Text("Everything on this list is done.")
                            .font(.title2)
                        Button("Close") { dismiss() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: 520)

            Spacer(minLength: 16)
        }
        .padding(28)
        .frame(minWidth: 460, idealWidth: 620, minHeight: 500, idealHeight: 600)
        .onAppear {
            if !didInit {
                didInit = true
                timerOn = store.settings.timerOnByDefault
                resetTimer()
            }
        }
        .onChange(of: current?.id) { _, _ in resetTimer() }
        .onReceive(tick) { _ in
            guard running, remaining > 0 else { return }
            remaining -= 1
            if remaining == 0 { running = false }
        }
    }

    @ViewBuilder
    private func stepView(_ step: Step) -> some View {
        VStack(spacing: 22) {
            Text("Next step")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.system(size: 32, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let m = step.minutes {
                Text("About \(m) min")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if let note = step.note, !note.isEmpty {
                Text(note).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            if step.hasChildren {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(step.children) { sub in
                        Button {
                            store.toggle(listID, sub.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: sub.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(sub.done ? Palette.accent : Color.secondary)
                                    .font(.system(size: 17))
                                Text(sub.title)
                                    .strikethrough(sub.done, color: .secondary)
                                    .foregroundStyle(sub.done ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if let m = sub.minutes {
                                    Text("\(m) min").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .frame(maxWidth: 440)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            }

            timerView(step)

            HStack(spacing: 14) {
                Button("Skip for now") { skip(step) }
                    .controlSize(.large)
                Button {
                    markDone(step)
                } label: {
                    Text("Done").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func timerView(_ step: Step) -> some View {
        VStack(spacing: 10) {
            Toggle("Timer", isOn: $timerOn)
                .toggleStyle(.switch)
                .controlSize(.small)
            if timerOn {
                Text(timeString(remaining))
                    .font(.system(size: 40, weight: .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.accent)
                HStack(spacing: 10) {
                    Button(running ? "Pause" : (remaining == 0 ? "Restart" : "Start")) {
                        if remaining == 0 { resetTimer() }
                        running.toggle()
                    }
                    Button("Reset") { resetTimer() }
                }
                if remaining == 0 {
                    Text("Time's up. Keep going or take a break. Either is fine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private func resetTimer() {
        running = false
        remaining = (current?.minutes ?? 5) * 60
    }

    private func skip(_ step: Step) {
        skipped.removeAll { $0 == step.id }
        skipped.append(step.id)
        // If everything left has been skipped, start the loop again.
        if let list, list.steps.filter({ !$0.done }).allSatisfy({ skipped.contains($0.id) }) {
            skipped = [step.id]
        }
    }

    private func markDone(_ step: Step) {
        store.setDone(listID, step.id, true)
        skipped.removeAll { $0 == step.id }
        withOptionalAnimation { celebrating = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            withOptionalAnimation { celebrating = false }
        }
    }

    private func withOptionalAnimation(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeInOut(duration: 0.25)) { change() } }
    }
}
