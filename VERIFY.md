# Desk Agent Verification

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Install / Relaunch

Only do this when no one is actively using the installed app:

```bash
./script/build_and_run.sh --install
```

## Smoke Render

```bash
.build/debug/MarkShot --smoke-render /tmp/markshot-permission-smoke.png --smoke-output /tmp/markshot-annotated-smoke.png
```

## Helper Checks

The helper bridge is expected on loopback during local development:

```bash
curl -sS http://127.0.0.1:4177/api/notch/status | jq .
curl -sS http://127.0.0.1:4177/api/live/config | jq .
```

## Manual UI Checks

- Launch the installed app.
- Expand/collapse the Notch.
- Open Hermes Sidecar.
- Send a text chat turn.
- Drag/drop a file into chat.
- Capture a screenshot and confirm the shelf/Quick Look/AirDrop actions still work.
- Start and stop live voice only when microphone permissions are intentionally being tested.

## Permission Notes

Do not automatically approve macOS Microphone, Camera, Screen Recording, Accessibility, or Local Network prompts. Stop and report the permission gate unless the user explicitly asks to approve it.
