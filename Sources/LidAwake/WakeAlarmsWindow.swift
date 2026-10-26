import AppKit
import LidAwakeCore
import LidAwakeShared
import SwiftUI

@MainActor
final class WakeAlarmsWindowController {
    private let preferences: WakePreferences
    private let scheduler: WakeScheduler
    private let setup: HelperSetup
    private let accent: AccentPreference
    private var window: NSWindow?

    init(preferences: WakePreferences, scheduler: WakeScheduler, setup: HelperSetup, accent: AccentPreference) {
        self.preferences = preferences
        self.scheduler = scheduler
        self.setup = setup
        self.accent = accent
    }

    func show() {
        if window == nil {
            let window = WakeAlarmsNSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Daily Alarms"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 380, height: 240)
            let host = NSHostingView(rootView: WakeAlarmsView(
                preferences: preferences, scheduler: scheduler, setup: setup, accent: accent
            ))
            host.sizingOptions = []
            window.contentView = host
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { window?.orderFrontRegardless() }
    }
}

private final class WakeAlarmsNSWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

struct WakeAlarmsView: View {
    @ObservedObject var preferences: WakePreferences
    @ObservedObject var scheduler: WakeScheduler
    @ObservedObject var setup: HelperSetup
    @ObservedObject var accent: AccentPreference
    @State private var editingError: String?

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(preferences.alarms) { alarm in
                    HStack(spacing: 16) {
                        DatePicker(
                            "Daily alarm time",
                            selection: Binding(
                                get: { WakeRow.date(minuteOfDay: alarm.minuteOfDay) },
                                set: { date in
                                    var edited = alarm
                                    edited.minuteOfDay = WakeRow.minuteOfDay(of: date)
                                    save(edited)
                                }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                        Toggle("Enabled", isOn: Binding(
                            get: { alarm.isEnabled },
                            set: { enabled in
                                var edited = alarm
                                edited.isEnabled = enabled
                                save(edited)
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel(Text("Enable alarm at \(WakeRow.time(minuteOfDay: alarm.minuteOfDay))"))
                        Button {
                            preferences.remove(id: alarm.id)
                            editingError = nil
                            if !preferences.hasEnabledAlarms { setup.cancelWake() }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Delete alarm at \(WakeRow.time(minuteOfDay: alarm.minuteOfDay))"))
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
            .overlay {
                if preferences.alarms.isEmpty {
                    Text("No alarms").foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let error = editingError ?? scheduler.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if setup.isPromptForWake, let prompt = setup.prompt {
                    Text(prompt.title).font(.headline)
                    Text(prompt.text(forWake: true)).fixedSize(horizontal: false, vertical: true)
                    if let title = prompt.actionTitle {
                        Button(title) { Task { await setup.performPromptAction() } }
                            .disabled(setup.isWorking)
                    }
                }
                HStack {
                    Button {
                        addAlarm()
                    } label: {
                        Label("Add Alarm", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(preferences.alarms.count >= ScheduledWake.maximumAlarms)
                    Spacer()
                }
            }
            .padding(14)
        }
        .tint(Palette.accent(accent.theme))
    }

    private func addAlarm() {
        let used = Set(preferences.alarms.map(\.minuteOfDay))
        guard let minute = (0..<1440).lazy.map({ (WakePreferences.defaultMinuteOfDay + $0) % 1440 })
            .first(where: { !used.contains($0) }) else { return }
        save(WakeAlarm(minuteOfDay: minute))
    }

    private func save(_ alarm: WakeAlarm) {
        guard preferences.save(alarm) else {
            editingError = "An alarm already uses that time, or the alarm limit has been reached."
            return
        }
        editingError = nil
        if !preferences.hasEnabledAlarms { setup.cancelWake() }
        if alarm.isEnabled {
            Task {
                guard preferences.hasEnabledAlarms else { return }
                await setup.requestWake()
            }
        }
    }
}
