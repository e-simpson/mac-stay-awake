<p align="center">
  <img src="./images/icon.png" width="96" alt="MacStayAwake icon: a white lid with amber wake rays" />
</p>
<h3 align="center">MacStayAwake</h3>
<p align="center">Keep your Mac working with the lid closed, then restore your settings.</p>
<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-black" alt="Platform: macOS" />
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license" /></a>
  <img src="https://img.shields.io/badge/status-experimental-yellow" alt="Status: experimental" />
</p>

A native menu-bar app for closed-lid work on battery or external power, inspired by [Vladimir Podgornyi's LidAwake](https://github.com/Vladimir-Podgornyi/LidAwake) and [deezeddd's LidAwake-Mac](https://github.com/deezeddd/LidAwake-Mac). It builds on the former's app/helper foundation and the latter's brightness-preservation approach.

## Screenshots

<p align="center">
  <img src="./images/normal-light.png" width="320" alt="Normal mode with compact settings and a duration picker" />
  <img src="./images/keep-alive-dark.png" width="320" alt="Keep alive with countdown, charging status, and nominal thermals" />
</p>

Screenshots use inert snapshot services and example state.

## Features

- **Keep alive**
  - Work with the lid closed on battery or external power; charging-only operation is optional.
  - Select **Normal** to restore temporary changes and return control to macOS. Right-click the menu-bar icon to toggle modes.
  - The panel follows system appearance/accent, with version information, Log, and Quit in its footer.
- **Display and energy settings**
  - Optionally save built-in brightness, set it to zero while closed, and enable Low Power Mode. Opening the lid or ending a session restores captured values.
  - Brightness zero does not guarantee the panel is physically powered off. Private DisplayServices APIs may change, unavailable panels defer restoration, and Low Power Mode can reduce performance.
- **Timers and safety**
  - Choose durations from two minutes to 24 hours, or **Infinite**. Defaults are two hours, a 20% battery cutoff, and thermal-pressure protection enabled.
  - The subtitle shows only enabled timer, battery/charging, and thermal fields. Other enabled safety limits still apply with Infinite selected.
  - Thermal protection does not guarantee safe operation in an enclosed bag. Legacy energy settings are refused when their original state cannot be restored safely.
- **Automation**
  - **App watching:** enable **Sleep when idle** and select apps whose launched commands should count as work. Enough consecutive quiet minutes ends Keep alive and restores its settings; macOS then controls sleep normally.
  - Watching estimates CPU activity and also considers system load, input, and other apps' keep-awake requests. It does not read Codex thread state, and model-response waits may appear idle. It does not start or restart Keep alive automatically; selected apps have no effect while Sleep when idle is disabled.
  - **Daily wake alarms:** add, edit, disable, or delete up to 16 distinct times. New alarms start disabled. Alarms intentionally survive Quit: the next two queued occurrences per enabled alarm remain while the app is closed; running the app replenishes them.
  - Lock-on-close and launch at login are opt-in. Upstream binary update checks are disabled.
- **Recovery and limits**
  - Quit restores temporary settings before exiting and retries automatically if a display or service is unavailable. Force Quit, shutdown deadlines, or power loss can interrupt recovery; restarting the app is required for interrupted brightness recovery.
  - Observable external setting changes are preserved. Avoid competing sleep-override utilities.
  - The app owns brightness recovery; an authenticated root helper owns bounded power operations, safety limits, and durable recovery records. Sessions require renewal and have a two-minute lease. See [the architecture](./docs/architecture/POWER_SESSIONS.md).

## Build and use

Source builds are available; public notarized downloads are not. Physical compatibility and recovery testing across Macs and macOS versions is incomplete.

1. Configure your own Developer ID Application identity using [SIGNING.md](./SIGNING.md). Production packaging deliberately refuses the default unconfigured signing team.
2. From the repository root, build and install:

   ```sh
   scripts/build-app.sh
   scripts/install-app.sh
   ```

3. Open `/Applications/MacStayAwake.app`, select **Keep alive**, and approve its helper in System Settings when prompted. Select **Normal** to restore the app's temporary changes and return control to your macOS settings.

Left-click opens the panel; right-click toggles Keep alive. **Infinite** disables the timer while retaining enabled safety limits. Installation does not launch the app, approve its helper, or change power settings. The installer refuses replacement: quit the previous app normally and move it to Trash before updating.

### Preview without a signing identity

```sh
PREVIEW_BUILD=1 scripts/build-app.sh
open build/preview/MacStayAwake.app
```

The preview uses inert power/brightness services and cannot register the helper. It cannot test closed-lid behavior. Avoid running a preview alongside an installed copy.

## Requirements

- The full Xcode application, including command-line tools and the asset compiler. Development checks used Xcode 27.1; older toolchains remain unverified.
- The package targets macOS 13 or later. This is a deployment target, not a verified hardware/OS support matrix.
- Your own Developer ID Application signing identity for real power control. Developer membership alone does not install that identity.

Apple silicon is the default. `ARCH=x86_64 scripts/build-app.sh` produces a separate app in `build/x86_64/` for manual installation. Intel compilation and physical acceptance remain unverified.

## Verify and contribute

```sh
swift test
PREVIEW_BUILD=1 scripts/build-app.sh
```

Tests and previews do not prove physical sleep, wake, or recovery behavior. Contributions should preserve bounded power operations, app/helper authentication, and restoration guarantees. Include a focused check for changed behavior. See [SECURITY.md](./SECURITY.md) for security reports.

The included CI workflow runs tests and builds the inert preview. It does not sign releases or use signing credentials. CI has not run on GitHub yet.

## Uninstall

Choose **Normal**, resolve any recovery message, and quit normally. Before moving the app to Trash, unregister its helper and cancel owned wake events:

```sh
/Applications/MacStayAwake.app/Contents/MacOS/LidAwake --uninstall-helper
```

Retain the app and recovery records if cleanup fails. Do not delete `/Library/Application Support/dev.personal.MacStayAwake` while recovery is pending. No sudoers grant is installed.

## License and credits

MIT. Preserve [LICENSE](./LICENSE) and [LICENSE-BRIGHTNESS-REFERENCE](./LICENSE-BRIGHTNESS-REFERENCE) for the corresponding code.

- [Vladimir-Podgornyi/LidAwake](https://github.com/Vladimir-Podgornyi/LidAwake): native app/helper foundation and retained icon. Upstream Git history is preserved.
- [deezeddd/LidAwake-Mac](https://github.com/deezeddd/LidAwake-Mac): brightness-preservation reference.

Exact source revisions and copyright notices are in [NOTICE](./NOTICE). MacStayAwake is independently maintained; attribution does not imply upstream endorsement.
