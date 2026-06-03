# Desk Agent Context

Read `PRODUCT.md` first for naming and product-boundary truth.

## Canonical Truth

This project is now **Desk Agent for Mac**, a Notch-first desktop app.

The folder, Swift package, and bundle still say `MarkShot` because the app started as a screenshot tool. That history matters for code paths, Screen Recording permissions, App Intents, Handoff ids, install scripts, and logs, but it is no longer the product definition.

The current product is:

- one Mac Notch surface for daily desk use
- one right-edge Hermes Sidecar that acts like an AI-OS layer
- one movable Hermes pop-out as a fallback/workbench chat window
- one iPhone companion surface for docked/remote use
- one helper/bridge layer for pairing, live voice, AirSend, approved actions, and provider routing
- Hermes as the current work-agent/chat adapter
- provider-swappable live voice and future agent adapters

## Mental Model

```text
User
  |
  +--> Mac Notch app
  |     - compact top Notch status and live voice entry
  |     - shared Hermes chat in top Notch, sidecar, and popout
  |     - right-edge Hermes Sidecar: Chat, Music, Mac, Vault, Servers, Actions, System
  |     - MarkShot screenshot shelf/capture module
  |     - notes, reminders, music, and service front doors
  |
  +--> iPhone app
        - Talk
        - Share Sheet intake
        - approvals / widgets / shortcuts

Both surfaces talk through the Desk Agent bridge contract.
```

## Current Surfaces

- `Sources/MarkShot/Views/NotchShelfView.swift`: main Notch UI and modules.
- `Sources/MarkShot/Models/AppState.swift`: shared app state, shelf batches, screenshot commands, quick notes.
- `Sources/MarkShot/Services/HermesDirectClient.swift`: local Hermes CLI chat adapter.
- `Sources/MarkShot/Services/DeskAgentBridgeClient.swift`: helper bridge client for readiness, status, AirSend, and live sessions.
- `Sources/MarkShot/Services/NotchLiveVoiceController.swift`: Swift controller for the hidden live web bridge.
- `Sources/MarkShot/Views/NotchLiveVoiceWebView.swift`: hidden `WKWebView` that loads the helper live shell.

## What Works Now

- Notch app launches as the visible Mac control surface.
- Hermes text chat is shared across top Notch chat, Hermes Sidecar chat, and movable pop-out chat.
- Hermes Sidecar slides out from the right edge with Chat, Music, Mac, Vault, Servers, Actions, and System sections.
- Chat accepts a shared attachment stack across top Notch, Sidecar, and pop-out: files, folders, images, videos, URLs, latest capture, clipboard, and Mac context.
- Visible local chat history is capped so the UI does not grow forever while Hermes keeps deeper continuity through the session id.
- The Sidecar Mac tab is a guarded Finder-style layer: browse with back/forward/up/breadcrumb navigation, multi-select, Quick Look, drag out, copy paths/files, paste copied files here, attach to Hermes, create folders/files, rename one item, zip selections, duplicate, open Terminal at the current folder, move selected items to a chosen folder with confirmation, move selected items to macOS Trash with confirmation, and copy dropped files into the current folder. Permanent delete and overwrite should remain explicit future work with confirmations.
- Screenshot capture, thumbnail stack, shelf batches, copy/save, annotation, and board workflows exist.
- MarkShot capture is now a module inside Desk Agent, not the product boundary.
- Quick notes append to a configurable inbox path.
- Music has a compact top Notch transport and a larger Sidecar browser surface for Spotify/Plex.
- Switchboard/Servers surfaces can read a configurable services registry.
- Apple-native Reminders, Quick Look, AirDrop, Share Sheet, Handoff groundwork, App Intents, and System Settings launch points exist in first-pass form.
- The hidden Notch `WKWebView` live bridge has explicit local microphone permission handling for the loopback helper live shell.

## Product Decisions

- The Notch app is the desktop app.
- The iPhone app is the companion, not a separate product.
- Hermes Sidecar is the growing AI-OS side layer.
- The movable Hermes pop-out remains a fallback/workbench, not the main side layer.
- The helper is service plumbing; it should not become another visible desktop UI.
- MarkShot remains the screenshot/shelf module and legacy code/package/bundle name until a deliberate rename pass happens.
- Rename should be staged later; do not do broad bundle/package renames while core behavior is still moving.

## Provider Strategy

Do not bake the product around one provider.

Current adapters:

- Hermes CLI for text/work chat.
- Gemini Live / Vertex through the helper.

Expected future adapters:

- OpenAI Realtime or ChatGPT-style multimodal API.
- Server-hosted agent bridge.
- Possible local agent runtime if it becomes practical.

The UI should talk about capabilities: live voice, screen context, work agent, media generation, approved action, session.

## Public Repo Notes

This public repo intentionally omits private handoff logs, pairing tokens, local server inventories, and user-specific path configuration. Machine-local paths should come from environment variables, user defaults, or ignored local notes.
