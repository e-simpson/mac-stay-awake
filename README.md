<p align="center">
  <img src="./images/icon.png" width="96" alt="MacStayAwake icon: a purple half-open eye and sparkle" />
</p>
<h3 align="center">MacStayAwake</h3>
<p align="center">A native mac app to keep your Mac working with the lid closed.</p>
<p align="center">inspired by <a href="https://github.com/Vladimir-Podgornyi/LidAwake">LidAwake</a> and <a href="https://github.com/deezeddd/LidAwake-Mac">LidAwake-Mac</a></p>
<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-black" alt="Platform: macOS" />
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license" /></a>
  <a href="https://github.com/e-simpson/mac-stay-awake"><img src="https://img.shields.io/github/stars/e-simpson/mac-stay-awake"></a>
</p>


<p align="center">
  <img src="./images/normal-light.png" width="320" alt="Normal mode with compact settings and a duration picker" />
  <img src="./images/keep-alive-dark.png" width="320" alt="Stay Awake with countdown, battery status, and nominal thermals" />
</p>

### Features

- Keep working with the lid closed, on battery or external power
- Dim the display and keyboard, mute audio, or enable Low Power Mode when closed
- Set a timer or run indefinitely, with battery and thermal cutoffs
- Automate with daily wake-ups and app watching
  - Watch app activity to end idle sessions
- Restore brightness and power settings when opening, stopping, or quitting

See [how it works and its limits](./docs/architecture/POWER_SESSIONS.md).

## Build and use

Source builds are available; public notarized downloads are not. Physical compatibility and recovery testing across Macs and macOS versions is incomplete.

1. Configure your own Developer ID Application identity using [SIGNING.md](./SIGNING.md). Production packaging deliberately refuses the default unconfigured signing team.
2. From the repository root, build and install:

   ```sh
   scripts/build-app.sh
   scripts/install-app.sh
   ```

3. Open `/Applications/MacStayAwake.app`, select **Stay Awake**, and approve its helper in System Settings when prompted. Select **Normal** to restore the app's temporary changes and return control to your macOS settings.

Left-click opens the panel; right-click toggles Stay Awake. **Infinite** disables the timer while retaining enabled safety limits. Installation does not launch the app, approve its helper, or change power settings. The installer refuses replacement: quit the previous app normally and move it to Trash before updating.

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

- [Vladimir-Podgornyi/LidAwake](https://github.com/Vladimir-Podgornyi/LidAwake): native app/helper foundation. Upstream Git history is preserved.
- [deezeddd/LidAwake-Mac](https://github.com/deezeddd/LidAwake-Mac): brightness-preservation reference.

Exact source revisions and copyright notices are in [NOTICE](./NOTICE). MacStayAwake is independently maintained; attribution does not imply upstream endorsement.
