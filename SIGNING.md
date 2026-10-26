# Signing and packaging

MacStayAwake requires a Developer ID Application identity for functional power control. The app and privileged helper authenticate each other using their bundle identifiers and configured signing team. Ad-hoc signing does not satisfy these requirements.

## Configure a local build

1. Create or install your own Developer ID Application identity in your login Keychain. Inspect available identities:

   ```sh
   security find-identity -v -p codesigning
   ```

2. Set `teamIdentifier` in [HelperConstants.swift](./Sources/LidAwakeShared/HelperConstants.swift) to your ten-character Apple Developer Team ID. The default, `UNCONFIGURED`, deliberately prevents production packaging. A Team ID is public metadata; private signing keys and account credentials must stay outside the repository.
3. Build from the repository root:

   ```sh
   scripts/build-app.sh
   ```

   The script selects a matching Developer ID Application identity. If several match, set `SIGN_IDENTITY` to the desired identity's SHA-1 fingerprint or complete name. `ARCH=x86_64` produces a separate Intel app.

4. The script signs both code objects with hardened runtime and timestamping, then verifies them against the same strict requirements used by XPC. A failed signature check is a failed build.
5. Install the Apple silicon build with `scripts/install-app.sh`. It refuses to overwrite an existing app and does not launch it or approve its helper. Open the app and follow macOS's normal helper-approval flow when ready.

Bundle identifiers remain `dev.personal.MacStayAwake` and `dev.personal.MacStayAwake.helper`. Executable/Swift target names remain `LidAwake` and `LidAwakeHelper`. Keep identifiers, LaunchDaemon metadata, and both peer requirements consistent when creating a separately identified fork. Do not change an installed app's identity without planning restoration and helper unregistration first.

## Preview without credentials

```sh
PREVIEW_BUILD=1 scripts/build-app.sh
```

The ad-hoc preview is packaged under `build/preview/` with a separate cache. It marks the bundle as a preview, compiles out helper registration, refuses real display-sleep assertions, and uses inert brightness handling. It cannot test power behavior. No unsigned trust bypass is provided.

## Public binary releases

Signing and notarization are separate. These scripts do not submit software to Apple or produce notarized downloads. Before distributing binaries, verify physical recovery and supported systems, sign with the release identity, notarize the distribution, and validate it on a clean Mac. No release credentials belong in source or untrusted pull-request workflows.

The scripts do not install certificates, modify Keychains, remove quarantine, approve a helper, or change power settings. Upstream binary update checks remain disabled.

Apple documents [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
