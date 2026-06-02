# Desk Agent Product Map

This file is the short truth source for naming and product boundaries.

## One Sentence

Desk Agent is a Notch-first Mac assistant: a persistent top Notch, a right-edge Hermes Sidecar, a movable chat pop-out, and a helper+iPhone bridge, with MarkShot capture folded in as one utility module.

## Names

- **Desk Agent**: the whole product/system.
- **Desk Agent Notch**: the primary Mac desktop surface in this repo.
- **Hermes Sidecar**: the right-edge AI-OS layer that slides out from the screen edge.
- **Hermes**: the current work-agent/chat brain behind the UI.
- **MarkShot**: the screenshot/capture/shelf module and the legacy repo/package/bundle name.
- **Desk Agent Helper**: the local bridge service for live voice, pairing, AirSend, approved actions, and provider routing.
- **Desk Agent iPhone**: the companion phone app for docked/remote Talk, share intake, approvals, and future camera/gesture ideas.

## Is MarkShot Separate?

No, not for daily product use.

MarkShot started as a standalone screenshot app, but it is now engulfed into Desk Agent as the capture/shelf utility module. Keep the capture behavior alive: hotkeys, floating thumbnails, shelf batches, Quick Look, AirDrop, clips, and note attachments all still matter.

Do not revive a separate visible MarkShot app or the old `DeskAgentMac.app` unless Will explicitly asks. The Mac desktop surface is this Notch app.

## Why The App Still Says MarkShot

The Swift package, source folder, bundle, installed app, TCC permissions, App Intents, Handoff activity id, scripts, and log identifiers still use `MarkShot`.

That is intentional for now. A broad package/bundle rename can break Screen Recording permissions, Accessibility trust, app intents, Handoff, install scripts, and future debugging. Rename only in a staged benchmark, after behavior stabilizes.

## Product Architecture

```text
Desk Agent
  |
  +-- Mac: Desk Agent Notch
  |     +-- top Notch: compact status, live voice, chat, music controls, shelf
  |     +-- Hermes Sidecar: Chat, Music, Mac, Vault, Servers, Actions, System
  |     +-- movable Hermes pop-out: fallback/workbench chat window
  |     +-- MarkShot module: capture, clips, shelf, Quick Look, AirDrop
  |
  +-- Helper: Desk Agent bridge on 127.0.0.1:4177
  |     +-- live voice provider adapter
  |     +-- Hermes/text/action routing
  |     +-- AirSend/share intake
  |     +-- approved local actions
  |
  +-- iPhone: Desk Agent companion
        +-- Talk and shared conversation surface
        +-- Share Sheet intake
        +-- approvals and future remote/camera surfaces
```

## Current Product Rules

- One primary desktop app: the Notch app in this repo.
- One primary agent conversation: Talk/Text to Hermes. Live voice, text chat, phone Talk, and future providers are modes of that one experience.
- Keep UI copy provider-neutral when possible. Say live voice, Hermes, bridge, session, helper, phone, Notch.
- Prefer Apple-native features before custom clones: AirDrop, Quick Look, Reminders, Shortcuts/App Intents, Handoff, Finder/System Settings, Share Sheet.
- Keep the top Notch calm and compact. Put bigger OS-layer workflows in the Hermes Sidecar.
- Use `MarkShot` only when discussing internal package/bundle identity or the capture/shelf module.

## Rename Plan

Current decision: keep the repo/package/bundle as `MarkShot` temporarily, but document the product as Desk Agent.

Safe staged order:

1. **Docs and agent truth**: keep `PRODUCT.md`, `AGENTS.md`, `CONTEXT.md`, `README.md`, and `TASKS.md` aligned.
2. **UI copy**: remove user-facing `MarkShot` except where macOS shows the installed app name.
3. **Module extraction**: split oversized Notch/capture/sidecar code only after behavior stabilizes.
4. **Package/bundle rename**: rename Swift package, bundle id, installed app name, scripts, App Intents, Handoff ids, permission reset docs, and logs in one deliberate benchmark.

Until step 4 happens, future agents should treat `MarkShot` as legacy/internal identity, not the product name.
