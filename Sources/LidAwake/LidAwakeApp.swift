import AppKit
import LidAwakeCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let helperClient: HelperClient
    let menuBarCountdown: MenuBarCountdown
    let modeController: ModeController
    let helperSetup: HelperSetup
    let launchAtLogin = LaunchAtLogin()
    let accent = AccentPreference(systemColorsChanged: NSColor.systemColorsDidChangeNotification)
    let autoLogout = AutoLogoutMonitor()
    let activityLog = ActivityLog()
    let sleepRecorder: SystemSleepRecorder
    let wakeScheduler: WakeScheduler
    private var rightClickMonitor: Any?
    private var isPreparingToQuit = false
    private(set) lazy var activityLogWindow = ActivityLogWindowController(log: activityLog, accent: accent, refresh: { [weak self] in
        await self?.modeController.refreshSettingEvents()
    })
    private(set) lazy var watchedAppsWindow = WatchedAppsWindowController(
        preferences: modeController.preferences,
        accent: accent
    )

    private(set) lazy var wakeAlarmsWindow = WakeAlarmsWindowController(
        preferences: wakeScheduler.preferences,
        scheduler: wakeScheduler,
        setup: helperSetup,
        accent: accent
    )

    override init() {
        helperClient = HelperClient()
        #if PERSONAL_PREVIEW
        let displayAssertion: PowerAssertion = PreviewPowerAssertion()
        let brightness: DisplayBrightnessControlling = PreviewBrightness()
        let closedLidSettings: ClosedLidSettingsControlling = NoClosedLidSettings()
        let settingEvents: SettingEventFetching = NoSettingEvents()
        #else
        let displayAssertion: PowerAssertion = DisplaySleepAssertion()
        let brightness: DisplayBrightnessControlling = DisplayBrightness(activityLog: activityLog)
        let closedLidSettings: ClosedLidSettingsControlling = ClosedLidSettings(activityLog: activityLog)
        let settingEvents: SettingEventFetching = XPCHelperConnection()
        #endif
        let controller = ModeController(
            displayAssertion: displayAssertion,
            helper: helperClient,
            sessions: XPCHelperConnection(),
            preferences: SafetyPreferences(),
            notifier: UserNotificationNotifier(),
            activityLog: activityLog,
            idleEvents: XPCHelperConnection(),
            settingEvents: settingEvents,
            brightness: brightness,
            closedLidSettings: closedLidSettings
        )
        let scheduler = WakeScheduler(
            preferences: WakePreferences(),
            helper: helperClient,
            service: XPCHelperConnection(),
            mode: controller,
            log: activityLog
        )
        wakeScheduler = scheduler
        sleepRecorder = SystemSleepRecorder(log: activityLog, wakeHandler: scheduler)
        menuBarCountdown = MenuBarCountdown(controller: controller)
        modeController = controller
        helperSetup = HelperSetup(
            helper: helperClient,
            dismissModeMessage: { controller.dismissMessage() },
            selectMode: { try await controller.select($0) },
            syncWake: { await scheduler.sync() }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, MenuBarWindow.isStatusClick(event) else { return false }
                Task {
                    guard !self.modeController.isQuitting else { return }
                    let target: Mode = self.modeController.mode == .lidClosed ? .off : .lidClosed
                    await self.helperSetup.select(target)
                    if self.modeController.mode != target || self.modeController.message != nil {
                        MenuBarWindow.show()
                    }
                }
                return true
            }
            return handled ? nil : event
        }
        sleepRecorder.start()
        wakeScheduler.start()
        Task {
            await helperClient.updateIfOutdated()
            await modeController.clearLeftover()
            await wakeScheduler.appDidLaunch()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isPreparingToQuit else { return .terminateLater }
        isPreparingToQuit = true
        Task {
            while !(await modeController.prepareToQuit()) {
                MenuBarWindow.show()
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    isPreparingToQuit = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            isPreparingToQuit = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
        wakeScheduler.appWillTerminate()
    }
}

struct LidAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                controller: appDelegate.modeController,
                preferences: appDelegate.modeController.preferences,
                helperSetup: appDelegate.helperSetup,
                launchAtLogin: appDelegate.launchAtLogin,
                accent: appDelegate.accent,
                autoLogout: appDelegate.autoLogout,
                openActivityLog: {
                    // The row is in the menu bar window, which is key while it is open.
                    if let window = NSApp.keyWindow {
                        MenuBarWindow.close(window)
                    }
                    appDelegate.activityLogWindow.show()
                },
                openWatchedApps: {
                    if let window = NSApp.keyWindow {
                        MenuBarWindow.close(window)
                    }
                    appDelegate.watchedAppsWindow.show()
                },
                openWakeAlarms: {
                    if let window = NSApp.keyWindow { MenuBarWindow.close(window) }
                    appDelegate.wakeAlarmsWindow.show()
                }
            )
        } label: {
            MenuBarIcon(controller: appDelegate.modeController, countdown: appDelegate.menuBarCountdown)
        }
        .menuBarExtraStyle(.window)
    }
}

#if PERSONAL_PREVIEW
/// Never reads saved brightness recovery or touches the real display.
@MainActor
private struct PreviewBrightness: DisplayBrightnessControlling {
    func sampleWhileOpen() -> DisplayBrightnessResult { .unavailable }
    func close() -> DisplayBrightnessResult { .unavailable }
    func restore() -> DisplayBrightnessResult { .unchanged }
}

/// A local UI preview must not change even the unprivileged sleep assertions.
private final class PreviewPowerAssertion: PowerAssertion {
    var isHeld: Bool { false }
    func acquire() throws {
        throw HelperError.notReady("UI preview: power controls are disabled until Developer ID signing is configured.")
    }
    func release() {}
}
#endif
