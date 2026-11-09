# Ymir

Ymir is a small native macOS menu-bar app for controlling a local `copilot-api` gateway used by Claude Code and Codex.

## Features

- Start and stop a pinned, tested release of `@jeffreycao/copilot-api`
- Sign in to `copilot-api` (runs `auth login --provider copilot` in a Terminal window)
- Show the signed-in GitHub username in the sign-in entry
- Sign out of Copilot after confirmation, stopping the gateway and removing only its saved Copilot token (settings and other providers' credentials are kept)
- Show a dimmed menu-bar icon when stopped, a spinner while starting/restarting, and the normal icon when running
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
- Node.js matching the pinned gateway's requirements: 22.23.4+, 24.22.1+, or 26.12.1+ on those supported release lines
- `copilot-api` auth completed once — use the app's **Sign In to copilot-api** menu item, or run:

```sh
npx --yes "@jeffreycao/copilot-api@$(cat Sources/Ymir/Resources/copilot-api-version.txt)" auth login --provider copilot
```

To sign out, choose **Sign Out of Copilot…** in Ymir's menu. This clears the
local token at `~/.local/share/copilot-api/github_token`; it does not revoke the
GitHub authorization or sign you out of other apps. Sign in and start the
gateway again when you want to reconnect.

The account name is looked up using the saved Copilot token and cached in memory
until that token changes. If GitHub is unavailable, the menu keeps sign-out
available and retries the lookup later.

Run the local authentication and menu-bar state tests with `swift test`.

## Notes

### Codex desktop

Merge these settings into `~/.codex/config.toml`, keeping your chosen model,
context limits, and other features:

```toml
[model_providers.copilot_api]
name = "OpenAI"
base_url = "http://localhost:4141"
model_catalog_url = "http://localhost:4141/models"
experimental_bearer_token = "dummy"
requires_openai_auth = false
supports_websockets = false
wire_api = "responses"
request_max_retries = 3
stream_max_retries = 3
stream_idle_timeout_ms = 300000

[features]
defer_mailbox_preemption = true
```

The public `dummy` placeholder lets Codex load the gateway's model catalog when
gateway client authentication is disabled on localhost. It needs no environment
variable and survives logout. If gateway API keys are enabled, replace
`experimental_bearer_token` with `env_key` pointing to an environment variable
containing a gateway key. The catalog can include upstream fallback entries;
`/v1/models` without a Codex User-Agent shows the gateway's discovered models.

Fully quit and reopen Codex after changing provider settings. Current Codex no
longer supports the old `remote_compaction_v2` feature flag; remove it from older
configurations. `defer_mailbox_preemption` is recommended by the gateway for
Copilot Multi-Agent V2 sessions.

### Gateway upgrades

[`Sources/Ymir/Resources/copilot-api-version.txt`](Sources/Ymir/Resources/copilot-api-version.txt)
is the single version pin used by startup, sign-in, and setup. Ymir logs the
package version when starting the gateway. Restarts do not select a newer npm
release automatically.

Run `make check-gateway` to download the pinned release without installing it,
check both compatibility adapters against its real server bundle, and verify
the adapted JavaScript parses. To evaluate an upgrade, run
`node scripts/check_gateway.mjs <exact-version>` first. Then update the version
file, run `node --test Tests/*.test.mjs` and `swift test`, and build/install with
`make release`. Include the real-Codex regression below when upgrading Codex or
the gateway. The bundle check verifies adapter boundaries and syntax, not live
upstream model behavior.

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

### Codex context window

The gateway's bundled Codex catalog advertises Astra with a 272,000-token
context window and an 872,000-token maximum, even when native Copilot advertises
1,050,000 tokens. Codex applies those catalog limits when fetching model metadata.
Ymir corrects the native Copilot Astra entry to use a 1,000,000-token default
(bounded by Copilot's live limit) and the live limit as its maximum. Other models,
provider aliases, instructions, and compaction settings are preserved.

With a 1M context setting, Codex reports 950,000 usable tokens after its 5%
headroom. A configured 800,000-token auto-compaction threshold remains unchanged.
Restart Codex after installing the correction to refresh its loaded catalog.

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

The separate early-compaction behavior seen in older Codex builds did not
reproduce with 0.167.0-alpha.3.2. Ymir preserves encrypted reasoning unchanged
and does not maintain a separate reasoning store.

Run the compatibility tests with `node --test Tests/codex-usage-compat.test.mjs`.
Run all adapter tests with `node --test Tests/*.test.mjs`. An optional regression
uses a real Codex binary and a synthetic local model endpoint, with no model API
calls. It checks that reasoning round-trips unchanged, compaction does not happen
prematurely below the threshold, normal compaction still happens above it, and
the corrected catalog gives a 950k usable window with either its default or an
explicit 1M setting:

```sh
YMIR_CODEX_TEST_BINARY=/path/to/codex node --test Tests/codex-compaction.integration.test.mjs
```

Ymir is a normal local native app bundle, not Electron. If your company profile blocks all unsigned or ad-hoc signed apps, build and run from Xcode or sign with an Apple Developer certificate trusted by your device management policy.
