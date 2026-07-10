# Ymir

Ymir is a small native macOS menu-bar app for controlling a local `copilot-api` gateway used by Claude Code and Codex.

## Features

- Start and stop `npx @jeffreycao/copilot-api@latest start`
- Sign in to `copilot-api` (runs `auth login --provider copilot` in a Terminal window)
- Show running/stopped state in the menu bar
- Browse every model advertised by the gateway and copy model IDs
- Open the `copilot-api` usage viewer
- Open local Codex and Claude Code config files
- Optional launch at login via macOS `SMAppService`
- Local notifications for start/stop/failure events
- Logs at `~/Library/Logs/Ymir/copilot-api.log`

## Build

Ymir builds as a standard macOS app from an Xcode project generated out of
[`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Quick start (fresh clone)

```sh
cd ~/Developer/Ymir
make bootstrap   # installs prerequisites and generates Ymir.xcodeproj
make release     # builds, installs to /Applications, and launches Ymir
```

`make bootstrap` runs [`scripts/setup.sh`](scripts/setup.sh): it verifies Xcode,
installs XcodeGen via Homebrew if missing, and regenerates the Xcode project. Run
`make help` to see all targets.

### Install / update the standalone app

```sh
cd ~/Developer/Ymir
chmod +x scripts/*.sh
scripts/release_app.sh
```

`scripts/release_app.sh` builds the Release configuration, installs the app to
`/Applications/Ymir.app`, and relaunches it. Re-run it to update the installed
app after code changes. Override the destination with
`DEST_DIR=~/Applications scripts/release_app.sh`.

### Develop in Xcode

```sh
xcodegen generate   # regenerate Ymir.xcodeproj after editing project.yml
open Ymir.xcodeproj
```

`project.yml` is the source of truth for the Xcode project. Signing defaults to
ad-hoc ("Sign to Run Locally"); pick a Team under Signing & Capabilities, or set
`DEVELOPMENT_TEAM` in `project.yml`, if your environment requires it.

## Requirements

- macOS 13+
- Xcode 15+ (or the Swift toolchain / command line tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project (`brew install xcodegen`)
- `npx` available from `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`
- `copilot-api` auth completed once — use the app's **Sign In to copilot-api** menu item, or run:

```sh
npx @jeffreycao/copilot-api@latest auth login --provider copilot
```

## Notes

Ymir is a normal local native app bundle, not Electron. If your company profile blocks all unsigned or ad-hoc signed apps, build and run from Xcode or sign with an Apple Developer certificate trusted by your device management policy.
