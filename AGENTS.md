# Desk Agent Project Router

This folder is the canonical Mac desktop surface for **Desk Agent**.

The historical repo/app name is **MarkShot**, because this began as a screenshot utility. Do not treat MarkShot as the current product boundary. MarkShot is now one module inside the Desk Agent Notch app.

## Read First

1. `PRODUCT.md` - naming and product boundary.
2. `CONTEXT.md` - current architecture and operating context.
3. `README.md` - public overview, install, and capture module notes.
4. `VERIFY.md` - build, install, helper, and manual smoke checks.
5. `BRIDGE_PROTOCOL.md` - provider-swappable helper/iPhone/Notch contract.
6. `DESK_AGENT_LOCAL_ACTION_CONTRACT.md` - local computer-use/action contract.
7. `APPLE_NATIVE_FEATURES_AUDIT.md` - Apple-native integration decisions.

## Current Product Boundary

- Mac desktop UI: this Notch app.
- Capture/shelf utility: MarkShot module inside this Notch app.
- Right-edge OS layer: Hermes Sidecar inside this Notch app.
- Helper/backend bridge: local service layer.
- iPhone companion: companion app layer.
- Reference Mac side apps are source material only; do not create a second visible Mac companion app unless explicitly requested.

## Working Rules

- Keep the Notch app as the single primary desktop surface.
- Keep the bridge provider-swappable: Gemini, OpenAI, Hermes, hosted agent, or future local agent must sit behind adapters.
- Use neutral product language in UI/docs: Desk Agent, live voice, Hermes/work agent, bridge, session.
- Preserve screenshot capture/shelf behavior; it is a daily utility module.
- Prefer Apple-native features for transfer, preview, Handoff, Reminders, Shortcuts/App Intents, and system integrations.
- Verify before handoff using `VERIFY.md`.

## Quick Start

```bash
swift build
./script/build_and_run.sh --install
```
