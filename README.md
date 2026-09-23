# Ymir

Ymir is a small native macOS menu-bar app for controlling a local `copilot-api` gateway used by Claude Code and Codex.

## Features

- Start and stop `npx @jeffreycao/copilot-api@latest start`
- Sign in to `copilot-api` (runs `auth login --provider copilot` in a Terminal window)
- Show running/stopped state in the menu bar
- Browse every model advertised by the gateway and copy model IDs
- Open local Codex and Claude Code config files
- Optional launch at login via macOS `SMAppService`
- Optional automatic gateway startup when Ymir launches
- Local notifications for start/stop/failure events
- Logs at `~/Library/Logs/Ymir/copilot-api.log`
- Correct Codex context accounting for GPT-6-Astra through Copilot Responses
- Use gateway chat models in Raycast AI, including models that require Responses

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
- Node.js 22.15+ (or 23.5+) for the gateway compatibility module
- `copilot-api` auth completed once — use the app's **Sign In to copilot-api** menu item, or run:

```sh
npx @jeffreycao/copilot-api@latest auth login --provider copilot
```

## Notes

### Raycast AI

Raycast Pro supports custom OpenAI-compatible providers. With the updated Ymir
gateway running, generate Raycast's provider configuration:

```sh
node scripts/configure_raycast.mjs
```

This writes `~/.config/raycast/ai/providers.yaml` with the gateway's current chat
models, their context limits, and supported abilities. Raycast reloads it
automatically. Select a model under **Ymir** in Raycast's model picker, or set
defaults in **Settings → AI → Models & Providers**. Keep Ymir's gateway running
while using these models. Requests use the gateway's existing Copilot account.
No Copilot token needs to be copied into Raycast.

Run the command again to refresh the model list. The generated file uses JSON,
which is valid YAML. Subsequent runs preserve other providers in JSON-formatted
configurations and back up the previous file. If you already have a non-JSON
YAML configuration, pass a separate output path and merge the `ymir` provider
into your existing `providers` list; the script refuses to overwrite it.

The local base URL is `http://127.0.0.1:4141/raycast/v1`. The Raycast route forwards
Chat Completions models directly and translates Responses-only models through
the gateway's `/v1/responses` endpoint. It handles text, images, function tools,
streamed output, usage, and cancellation. Embedding models are excluded. Existing
Codex and Claude Code routes are unchanged. The gateway loader checks the route
boundary and fails explicitly if a future gateway version changes it.

Run all compatibility tests with `node --test Tests/*.test.mjs`.

### Codex usage accounting

Ymir preloads a small compatibility module when launching the gateway. Copilot's
GPT-6-Astra Responses usage includes retained reasoning, but its response lacks
the `x-reasoning-included` capability header that Codex expects. Without that
header, Codex adds an estimate of older reasoning again and may compact early.
The module adds the header only to that model's native Copilot Responses route.
It leaves usage values and Codex's compaction limits unchanged, works with HTTP
and WebSocket upstream transport, and does not edit the npm cache. The loader
checks the handler shape and reports an error if a future proxy release changes
it, rather than applying an unverified rewrite.

Codex 0.155.0-alpha.9.2 also resets this capability before its check at the start
of a new user turn. That check runs before any gateway response, so it can still
compact early even with this fix. Removing that remaining behavior requires a
Codex client change; Ymir's adapter fixes the accounting during a running turn.

Run the compatibility tests with `node --test Tests/codex-usage-compat.test.mjs`.

Ymir is a normal local native app bundle, not Electron. If your company profile blocks all unsigned or ad-hoc signed apps, build and run from Xcode or sign with an Apple Developer certificate trusted by your device management policy.
