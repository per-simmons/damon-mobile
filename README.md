# Damon Mobile

A Claude-style chat client for the coding agents running in **Damon** on a Mac. It comes as a native iPhone app (SwiftUI) and a web app, and it talks to a small server on the Mac over Tailscale.

- **Sidebar:** Damon projects → workspaces (agents) → tabs (chats), with live status: working, needs you, done.
- **Chat:** the real Claude Code or Codex conversation running in that Damon pane, shown as messages. Replies arrive live.
- **Sending** types into the actual pane, so the phone and the desktop are the same conversation. Permission prompts get Allow / Always / Deny buttons, plus Stop and a keys row.
- **New chat** (+) opens a Claude Code or Codex tab in Damon. You can also dictate, rename chats and attach images.

## Requirements

- A Mac running **Damon** with its local control API (`~/.damon/control-api.token` and `.port`, with `/control/list`, `/control/send-text`, `/control/open-tab`, and `/control/rename-tab` for renaming). Damon is a fork of Superset. This project does nothing without it.
- Claude Code and/or the Codex CLI running in Damon terminal tabs.
- [Bun](https://bun.sh) on the Mac.
- [Tailscale](https://tailscale.com) on the Mac and on the phone, signed into the same tailnet.
- For the iPhone app: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and an Apple developer account.

## Security model (read this)

The phone can do anything your agents can: it types into live terminals that may be running with permissions skipped. So:

- The server listens **only** on `127.0.0.1` and on the Mac's Tailscale IP. It is never on your LAN or the internet.
- Every request over Tailscale is checked with `tailscale whois`, and it must come from a device logged in as `DAMON_MOBILE_LOGIN`. Results are cached for 10 minutes.
- Requests from a different web origin (including WebSocket upgrades) are rejected, so a web page in your browser can't reach the server.
- Damon's control token is read from disk on the Mac and never leaves it.
- Images you send are written to `~/.damon-mobile/uploads` on the Mac, and only their file paths are passed to the agent.
- No telemetry, no third-party services. Treat Tailscale ACLs as part of this setup, and don't share the tailnet with anyone you wouldn't hand your terminal to.

## Server setup (on the Mac)

```bash
git clone <this repo> damon-mobile && cd damon-mobile
export DAMON_MOBILE_TS_IP=$(tailscale ip -4)          # this Mac's tailnet IP
export DAMON_MOBILE_LOGIN=you@example.com              # your Tailscale login (see `tailscale status --json`)
bun run server.ts                                      # serves http://$DAMON_MOBILE_TS_IP:8787
```

To keep it running in the background, fill in `launchd/damon-mobile.plist.template` and load it with `launchctl bootstrap`. Optional settings: `DAMON_MOBILE_PORT` (default 8787).

So Claude Code can open images sent from the phone without a permission prompt, add the uploads folder to `~/.claude/settings.json`:

```json
{ "permissions": { "additionalDirectories": ["/Users/<you>/.damon-mobile/uploads"] } }
```

## Web app

Open `http://<mac-tailnet-ip>:8787` on any device in your tailnet. On iPhone, use Share → Add to Home Screen.

## iPhone app

```bash
cd ios
DEVELOPMENT_TEAM=<your team id> BUNDLE_ID=com.<you>.damon DEVICE=<id from `xcrun devicectl list devices`> ./install.sh
```

On first launch, tap the dot (top right) → **Server address** and enter `http://<mac-tailnet-ip>:8787`. Development installs expire with their provisioning profile (a year on a paid account); re-run `install.sh` to renew. Turn on Tailscale's **VPN On Demand** on the phone, or iOS will drop the connection in the background.

## Known limits

- Replies arrive a block at a time. Claude writes each finished block to its transcript, so there's no letter-by-letter streaming.
- A brand-new Claude chat appears once Damon maps the pane to its session, which can take up to about 45 s after the first message.
- Multiple-choice prompts map options to number keys. For anything else, use the keys row or the desktop.

## Demo recording (optional)

`demo/make-codex-demo.sh <simulator-udid>` records a demo in the iPhone simulator, driven by XCUITest, with on-screen touch circles. It cuts the video automatically from what's on screen. Set `DEMO_AGENT` to a workspace name. The app hides everything except the demo chat when launched with `-demo`.
