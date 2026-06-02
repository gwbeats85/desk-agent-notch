# Desk Agent Public Task Snapshot

This file is a public-safe milestone snapshot. Private session logs and machine-specific handoffs should stay in ignored local notes.

## Current Focus

- Keep Desk Agent as one Notch-first Mac desktop app.
- Keep MarkShot as the capture/shelf module inside Desk Agent.
- Keep Hermes chat unified across top Notch, Hermes Sidecar, and pop-out chat.
- Keep provider routing swappable behind the helper/bridge contract.
- Keep Apple-native features first: AirDrop, Quick Look, Reminders, Shortcuts/App Intents, Handoff, Share Sheet.

## Completed Public Milestones

- MarkShot screenshot/capture/shelf module works as the legacy utility layer.
- Desk Agent product map and naming docs are consolidated.
- Top Notch, Hermes Sidecar, and movable pop-out share a common chat direction.
- Sidecar sections exist for Chat, Music, Mac, Vault, Servers, Actions, and System.
- Local action contract documents the safe observe/ground/act/validate direction.
- Public repo has been sanitized to avoid API keys, pairing tokens, private server URLs, and machine-specific handoff logs.

## Next Public Milestones

- Continue extracting large SwiftUI modules after behavior stabilizes.
- Replace remaining machine-specific defaults with configurable settings UI.
- Add richer attachment preview/actions for videos and folders.
- Harden music provider control across Spotify/Plex through explicit adapters.
- Add public tests around path configuration and bridge status rendering.
