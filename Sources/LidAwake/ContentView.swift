import AppKit
import LidAwakeCore
import LidAwakeShared
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: ModeController
    @ObservedObject var preferences: SafetyPreferences
    @ObservedObject var helperSetup: HelperSetup
    @ObservedObject var launchAtLogin: LaunchAtLogin
    @ObservedObject var accent: AccentPreference
    @ObservedObject var autoLogout: AutoLogoutMonitor
    let openActivityLog: () -> Void
    let openWatchedApps: () -> Void
    let openWakeAlarms: () -> Void
    var heightLimit: HeightLimit = .screen

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var screenLimit: CGFloat?
    @State private var fixedHeight: CGFloat = 0
    @State private var scrollingContentHeight: CGFloat = 0
    @FocusState private var focusedCard: Mode?
    /// The card focus as it was before a mode switch: the cards are disabled while one runs,
    /// which takes the focus off them.
    @State private var cardFocus: Mode?
    /// The selected mode the card focus last followed.
    @State private var followedMode: Mode = .off
    @State private var isWindowKey = false

    private let power = IOKitPowerSource()
    private let isSystem26OrLater = WindowLook.isSystem26OrLater

    /// How tall the window may get.
    enum HeightLimit {
        /// The visible area of the screen the window is on, measured from the window's real frame.
        case screen
        /// A set height, or none.
        case fixed(CGFloat?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                header
                VStack(spacing: 0) {
                    Divider().padding(.bottom, 4)
                    modeRows
                    Divider().padding(.top, 4)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .padding(.horizontal, 14)
            .background(HeightReader(height: $fixedHeight))
            if let scrollHeight {
                // No background of its own, so Glass and Solid look the same as without scrolling.
                ScrollView(.vertical) {
                    scrollingContent
                }
                .frame(height: scrollHeight)
            } else {
                scrollingContent
            }
        }
        .frame(width: 320, alignment: .leading)
        .background(WindowGeometryReader(limit: $screenLimit, isScrolling: scrollHeight != nil))
        .background(WindowKeyReader(isKey: $isWindowKey))
        .background(look.drawsOwnBackground ? Palette.solidWindowBackground : .clear)
        .tint(Palette.accent(.system))
        .onAppear {
            launchAtLogin.refresh()
            autoLogout.refresh()
            followedMode = controller.mode
        }
        // Only this window: the activity log window becoming key leaves the cards alone.
        .onChange(of: isWindowKey) { isKey in
            guard isKey else { return }
            launchAtLogin.refresh()
            autoLogout.refresh()
            // After AppKit has given focus to the first card as the window opens.
            DispatchQueue.main.async {
                followedMode = controller.mode
                cardFocus = OpeningFocus.card(selected: controller.mode)
                focusedCard = cardFocus
            }
        }
        .onChange(of: controller.mode) { _ in
            autoLogout.refresh()
            followSelection()
        }
        .onChange(of: controller.isBusy) { _ in followSelection() }
        .onChange(of: focusedCard) { focus in
            if !controller.isBusy {
                cardFocus = focus
            }
        }
    }

    /// Once a switch is over, gives a focused card's focus to the selected card, or back to the
    /// card it was taken from. When the selection changed, the focus is taken off first and given
    /// on the next turn, after the cards have their new sizes: the system focus ring keeps the
    /// bounds the card had when it got the focus.
    private func followSelection() {
        guard !controller.isBusy else { return }
        let previous = followedMode
        followedMode = controller.mode
        guard let target = OpeningFocus.card(focused: cardFocus, previous: previous, selected: controller.mode) else {
            return
        }
        let selectionChanged = previous != controller.mode
        guard selectionChanged || focusedCard != target else { return }
        cardFocus = target
        if selectionChanged {
            focusedCard = nil
        }
        DispatchQueue.main.async {
            focusedCard = target
        }
    }

    /// Everything below the mode cards; it scrolls when the window would not fit on the screen.
    private var scrollingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !messages.isEmpty {
                messageBlock.padding(.bottom, 8)
            }
            settingsRows
            Divider().padding(.vertical, 4)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .background(HeightReader(height: $scrollingContentHeight))
    }

    private var maxHeight: CGFloat? {
        switch heightLimit {
        case .screen: return screenLimit
        case .fixed(let height): return height
        }
    }

    private var scrollHeight: CGFloat? {
        WindowHeightLimit.scrollHeight(
            fixedHeight: fixedHeight,
            contentHeight: scrollingContentHeight,
            maxHeight: maxHeight
        )
    }

    private var header: some View {
        Text(verbatim: "MacStayAwake")
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("Version \(AppVersion.installedText)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Spacer(minLength: 0)
            Button("Log", action: openActivityLog)
                .help("Activity log")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 13))
        .buttonStyle(MenuRowButtonStyle(extendsToMargin: false))
    }

    private var statusLine: String? {
        let reading = power.read()
        return StatusLine.text(
            mode: controller.mode,
            isPaused: controller.isPaused,
            timerRemaining: controller.timerRemaining(),
            battery: controller.mode == .lidClosed && preferences.batteryLimitEnabled ? reading.battery : .none,
            powerSource: reading.source,
            thermal: preferences.thermalProtectionEnabled ? ProcessInfoThermalState().read() : nil
        )
    }

    private var modeRows: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            VStack(spacing: 0) {
                ModeRow(mode: .off, isSelected: controller.mode == .off) {
                    Task { await helperSetup.select(.off) }
                } controls: {
                    EmptyView()
                }
                .focused($focusedCard, equals: .off)
                ModeRow(
                    mode: .lidClosed,
                    isSelected: controller.mode == .lidClosed,
                    subtitle: statusLine,
                    subtitleIsActive: !controller.isPaused
                ) {
                    Task { await helperSetup.select(.lidClosed) }
                } controls: {
                    ValueMenu(
                        label: "Keep alive duration",
                        selection: Binding(
                            get: { preferences.timerEnabled ? preferences.timerSeconds : 0 },
                            set: { seconds in
                                if seconds > 0 { preferences.timerSeconds = seconds }
                                preferences.timerEnabled = seconds > 0
                            }
                        ),
                        choices: [0] + MenuChoices.list(SafetyPreferences.timerChoices, current: preferences.timerSeconds),
                        title: { $0 == 0 ? String(localized: "Infinite") : DurationFormat.choice($0) }
                    )
                }
                .focused($focusedCard, equals: .lidClosed)
            }
            .disabled(controller.isBusy || controller.isQuitting)
        }
    }

    private var messages: [WindowMessage] {
        WindowMessage.list(
            helper: helperSetup.prompt,
            helperForWake: helperSetup.isPromptForWake,
            mode: controller.message,
            autoLogout: autoLogout.notice(
                mode: controller.mode,
                timerSeconds: preferences.timerEnabled ? preferences.timerSeconds : nil
            ),
            update: nil
        )
    }

    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(messages) { message in
                MessageBanner(
                    message: message,
                    look: look,
                    isActionDisabled: message.source == .helper && helperSetup.isWorking,
                    dismiss: message.isDismissible ? { autoLogout.dismiss() } : nil
                ) {
                    switch message.source {
                    case .update:
                        break
                    case .autoLogout:
                        openAutoLogoutSettings()
                    case .helper, .mode:
                        Task { await helperSetup.performPromptAction() }
                    }
                }
            }
        }
    }

    /// Tries the Advanced anchor first; if System Settings refuses it, opens the section.
    private func openAutoLogoutSettings() {
        NSWorkspace.shared.open(AutoLogoutLinks.advancedSettings, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(AutoLogoutLinks.privacySettings)
            }
        }
    }

    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: "Display off when closed", isOn: $preferences.displayOffWhenClosed) {
                SwitchToggle(title: "Display off when closed", isOn: $preferences.displayOffWhenClosed)
            }
            SettingRow(title: "Low power when closed", isOn: $preferences.lowPowerWhenClosed) {
                SwitchToggle(title: "Low power when closed", isOn: $preferences.lowPowerWhenClosed)
            }
            SettingRow(title: "Stop when hot", isOn: $preferences.thermalProtectionEnabled) { thermalToggle }
            SettingRow(title: "Stop below battery %", isOn: $preferences.batteryLimitEnabled) {
                batteryValue
                batteryToggle
            }
            .opacity(preferences.batteryLimitApplies ? 1 : 0.45)
            .disabled(!preferences.batteryLimitApplies)
            lockRow(minHeight: 24)
            SettingRow(title: "Only while charging", isOn: $preferences.chargingOnlyEnabled) { chargingToggle }
            Divider().padding(.vertical, 4)
            launchRow
            NavigationRow(title: "Wake-up alarms", action: openWakeAlarms)
            NavigationRow(title: "Watched apps", action: openWatchedApps)
        }
    }

    private var thermalToggle: some View {
        SwitchToggle(title: "Stop when hot", isOn: $preferences.thermalProtectionEnabled)
    }

    private var batteryValue: some View {
        ValueMenu(
            label: "Battery limit",
            selection: $preferences.batteryLimitPercent,
            choices: MenuChoices.list(SafetyPreferences.batteryLimitChoices, current: preferences.batteryLimitPercent),
            title: DurationFormat.percent
        )
    }

    private var batteryToggle: some View {
        SwitchToggle(title: "Stop below battery %", isOn: $preferences.batteryLimitEnabled)
    }

    private var chargingToggle: some View {
        SwitchToggle(title: "Only while charging", isOn: $preferences.chargingOnlyEnabled)
    }

    private func lockRow(minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingRow(title: "Lock screen when the lid closes", isOn: $preferences.lockOnLidCloseEnabled, minHeight: minHeight) {
                SwitchToggle(title: "Lock screen when the lid closes", isOn: $preferences.lockOnLidCloseEnabled)
            }
            if let notice = controller.screenLockNotice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var launchRow: some View {
        let enabled = Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
        return SettingRow(title: "Launch at login", isOn: enabled) {
            SwitchToggle(title: "Launch at login", isOn: enabled)
                .disabled(!launchAtLogin.isInApplications)
        }
        .help(launchAtLogin.notice?.text ?? String(localized: "Launch at login"))
    }

    private var look: WindowLook {
        WindowLook(style: .glass, isSystem26OrLater: isSystem26OrLater, reduceTransparency: reduceTransparency)
    }


}

private extension Mode {
    var title: LocalizedStringKey {
        switch self {
        case .off: return "Normal"
        case .keepScreenOn: return "Keep Screen On"
        case .lidClosed: return "Keep alive"
        }
    }

}

private struct ModeRow<Controls: View>: View {
    let mode: Mode
    let isSelected: Bool
    var subtitle: String? = nil
    var subtitleIsActive = false
    let action: () -> Void
    @ViewBuilder let controls: Controls

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 10) {
                    ModeIconView(mode: mode)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mode.title)
                            .font(.system(size: 14))
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(subtitleIsActive ? Color.green : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(mode.title))
            .accessibilityValue(Text(subtitle ?? ""))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            controls
        }
        .padding(.vertical, 4)
        .modifier(MenuRowHighlight(isSelected: isSelected))
        .opacity(isEnabled ? 1 : 0.6)
    }
}

private extension MessageKind {
    var symbol: String {
        switch self {
        case .actionNeeded: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        case .info: return "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .actionNeeded: return .orange
        case .error: return .red
        case .info: return .secondary
        }
    }

    func background(_ look: WindowLook) -> Color {
        switch self {
        case .actionNeeded: return Color.orange.opacity(0.14)
        case .error: return Color.red.opacity(0.12)
        case .info: return Palette.cardBackground(look)
        }
    }

    func border(_ look: WindowLook) -> Color {
        switch self {
        case .actionNeeded: return Color.orange.opacity(0.45)
        case .error: return Color.red.opacity(0.45)
        case .info: return Palette.cardBorder(look)
        }
    }
}

private struct MessageBanner: View {
    let message: WindowMessage
    let look: WindowLook
    let isActionDisabled: Bool
    var dismiss: (() -> Void)?
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.kind.symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .foregroundStyle(message.kind.iconColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(message.text)
                        .font(.system(size: 12))
                    if let hint = message.hint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                if let actionTitle = message.actionTitle {
                    Button(action: action) {
                        Text(actionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(message.source == .helper ? .defaultAction : nil)
                    .disabled(isActionDisabled)
                }
            }
            Spacer(minLength: 0)
        }
        // The border is drawn inside the banner, so 13 matches the mockup's 12 padding plus a 1 border.
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(message.kind.background(look)))
        .overlay(shape.strokeBorder(message.kind.border(look), lineWidth: 1))
        // The stack's spacing before the spacer keeps 10 points right of the text free, so the
        // button, 3 points in from the corner, never covers the title.
        .overlay(alignment: .topTrailing) {
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .help(Text("Dismiss"))
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Uses macOS selection colors without replacing the native controls inside a row.
private struct MenuRowHighlight: ViewModifier {
    var isPressed = false
    var extendsToMargin = true
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let highlighted = isEnabled && (isHovered || isPressed)
        let background = highlighted ? Color(nsColor: .selectedContentBackgroundColor)
            : isSelected ? Color.primary.opacity(0.06) : .clear
        content
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(background)
            }
            .foregroundStyle(highlighted ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
            .onHover { isHovered = $0 }
            .padding(.horizontal, extendsToMargin ? -8 : 0)
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    var extendsToMargin = true
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 24)
            .modifier(MenuRowHighlight(isPressed: configuration.isPressed, extendsToMargin: extendsToMargin, isSelected: isSelected))
    }
}

private struct NavigationRow: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .opacity(0.65)
            }
            .font(.system(size: 13))
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct SettingRow<Controls: View>: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool
    var minHeight: CGFloat = 24
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isOn.toggle()
            } label: {
                HStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) { controls }
        }
        .frame(minHeight: minHeight)
        .modifier(MenuRowHighlight())
    }
}

struct SwitchToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// A value in a rounded "pill" that opens a menu of choices.
struct ValueMenu: View {
    let label: LocalizedStringKey
    @Binding var selection: Int
    let choices: [Int]
    let title: (Int) -> String

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(choices, id: \.self) { value in
                    Text(title(value)).tag(value)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(title(selection))
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // A borderless menu draws its title in the tint color.
        .tint(.primary)
        .fixedSize()
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.valueBackground))
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(title(selection)))
    }
}

private struct HeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.height) }
                .onChange(of: proxy.size.height) { update($0) }
        }
    }

    private func update(_ value: CGFloat) {
        if value != height {
            height = value
        }
    }
}

/// Reports whether the window the view is in is the key window.
private struct WindowKeyReader: NSViewRepresentable {
    @Binding var isKey: Bool

    func makeNSView(context: Context) -> WindowKeyView {
        let view = WindowKeyView()
        view.onChange = { value in
            if value != isKey {
                isKey = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowKeyView, context: Context) {}
}

private final class WindowKeyView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else {
            report(false)
            return
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                self?.report(window?.isKeyWindow ?? false)
            })
        }
        report(window.isKeyWindow)
    }

    private func report(_ isKey: Bool) {
        // Not during a view update: the value goes into SwiftUI state.
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(isKey)
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// Watches the window's real frame and screen and reports how tall the content may be.
private struct WindowGeometryReader: NSViewRepresentable {
    @Binding var limit: CGFloat?
    let isScrolling: Bool

    func makeNSView(context: Context) -> WindowGeometryView {
        let view = WindowGeometryView()
        view.onChange = { value in
            if value != limit {
                limit = value
            }
        }
        return view
    }

    func updateNSView(_ nsView: WindowGeometryView, context: Context) {
        nsView.isScrolling = isScrolling
    }
}

private final class WindowGeometryView: NSView {
    var onChange: ((CGFloat?) -> Void)?
    var isScrolling = false
    private var fit = WindowFit()
    private var observers: [NSObjectProtocol] = []
    private var loggedHeight: CGFloat?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        fit.reset()
        guard let window else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, object: Any?, _ handler: @escaping (WindowGeometryView) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                guard let self else { return }
                handler(self)
            })
        }
        // The menu bar window can open on another screen each time, and the Dock can move.
        observe(NSWindow.didBecomeKeyNotification, object: window) { $0.measure(isOpening: true) }
        observe(NSWindow.didResizeNotification, object: window) { $0.measure(isOpening: false) }
        observe(NSWindow.didMoveNotification, object: window) { $0.measure(isOpening: false) }
        observe(NSWindow.didChangeScreenNotification, object: window) { view in
            view.fit.reset()
            view.measure(isOpening: false)
        }
        observe(NSApplication.didChangeScreenParametersNotification, object: nil) { view in
            view.fit.reset()
            view.measure(isOpening: false)
        }
        measure(isOpening: true)
    }

    private func measure(isOpening: Bool) {
        guard let window, let screen = window.screen, let content = window.contentView else { return }
        let geometry = WindowGeometry(
            visibleFrame: screen.visibleFrame,
            windowFrame: window.frame,
            contentHeight: content.frame.height
        )
        let limit = fit.update(geometry)
        if WindowGeometryLog.isEnabled, isOpening || loggedHeight != window.frame.height {
            loggedHeight = window.frame.height
            print(WindowGeometryReport.line(geometry, limit: limit, isScrolling: isScrolling))
            fflush(stdout)
        }
        // Not during a view update: the value goes into SwiftUI state.
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(limit)
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
