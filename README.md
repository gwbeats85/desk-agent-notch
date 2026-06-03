# Desk Agent for Mac

This folder is the canonical Mac desktop surface for **Desk Agent**: a Notch-first Mac assistant with a compact top Notch, a right-edge Hermes Sidecar, a movable Hermes pop-out, a helper+iPhone bridge, and the old MarkShot capture workflow folded in as a module.

Historical name warning: the repo, Swift package, and installed bundle still use **MarkShot** because this started as a screenshot app. Do not treat MarkShot as the current product boundary. The screenshot/capture/shelf workflow is now one Desk Agent module inside the Notch app.

Start new agent work here:

- `AGENTS.md`
- `PRODUCT.md`
- `CONTEXT.md`
- `TASKS.md`
- `VERIFY.md`
- `BRIDGE_PROTOCOL.md`

## Product Map

- **Desk Agent** is the whole product/system.
- **Desk Agent Notch** is the primary Mac UI in this repo.
- **Hermes Sidecar** is the right-edge AI-OS layer with Chat, Music, Mac, Vault, Servers, Actions, and System sections.
- **Hermes pop-out** is the movable fallback/workbench chat window.
- **MarkShot** is now the capture/screenshot/shelf module and the legacy package/bundle name.
- **Desk Agent Helper** is the local bridge service.
- **Desk Agent iPhone** is the companion phone app.

## Current App Surfaces

- Compact top Notch status display, live voice button, chat, shelf count/status, and music transport.
- Expanded top Notch for daily modules.
- Right-edge Hermes Sidecar for larger OS-layer workflows.
- Movable Hermes pop-out for a draggable/compact chat workbench.
- MarkShot capture hotkeys, floating thumbnails, screenshot shelf, clips, Quick Look, AirDrop, and note attachment workflows.

## MarkShot Capture Module

Native macOS notch-first screenshot + annotation app for quick AI/design markup. Menu bar utility, notch shelf, lower-right capture stack, pin screenshots to screen, record clips for VideoFrame Lab.

Path map: `PATHS.md`

## What Works

**Capture**
- Full screen capture (fast, no process spawn).
- Selected region capture (interactive macOS selection).
- Selected window capture (click to choose window).
- The bottom toolbar stays hidden until editing/board mode. During capture, a small thumbnail appears in the lower-right corner.
- Multiple smaller captures stack upward like macOS screenshot thumbnails.
- Click a thumbnail to open it in the editor, or hover it to send the stack to the notch shelf, copy, or dismiss without opening the editor.
- Hover any thumbnail and use the shelf button to move the whole current thumbnail stack into the notch shelf as one batch. Menu bar → Save All Capture Thumbnails still saves the current stack to a folder.
- Delay capture — 3s or 5s countdown via the timer menu in the toolbar. Toolbar stays visible so you can set up what you want to capture (open a menu, hover a state, etc.) before the shot fires.
- Record a selected-area video clip via the Record button or menu bar, click Record again to stop, then find the saved `.mov` in Shelf or send it straight to VideoFrame Lab from the toolbar.
- Open VideoFrame Lab from MarkShot. If the local server is not running, MarkShot starts it on port 3000 or the next free port, then auto-stops it after 30 idle minutes.

**Board**
- New board opens a dot-grid canvas for quick diagrams and layout sketches.
- Board mode adds quick layout blocks: header, card, tag, button, input.
- Boards open in pointer mode — pick a block tool before drawing.

**Annotate**
- The editor opens only after clicking a captured thumbnail or starting a board.
- Arrow, rectangle/highlight box, ellipse/circle, freehand pen, text label, redact box.
- Text is inline: choose Text, click the canvas, type in the small floating field, Enter to place, Esc to cancel.
- Undo, redo, clear all annotations.
- Red, yellow, black, white, or a custom color picker.
- Adjustable stroke width.

**Export**
- Copy annotated PNG to clipboard (Cmd+C). Hides after successful copy.
- Save annotated PNG via native save panel (Cmd+S), defaults to `~/screenshots`.
- Drag PNG chip in the toolbar — exports as PNG data + temporary file.
- Pin to screen — pins the rendered screenshot as a floating always-on-top window. Multiple pins supported, each offset so they tile. Hover any pin for the close X. Pin count shows on the Pin button.
- Clear all pinned screenshots via the pin.slash button or menu bar.

**Menu Bar**
- Show / hide toolbar (global hotkeys stay active while hidden).
- New Board, all capture modes, Record Clip, Open/Stop VideoFrame Lab, Clear All Pinned, Quick Reference, Quit.

**Notch Shelf**
- Compact top-center shelf leaves the physical notch center clear and places small controls in the left/right wings.
- Compact status shows live voice, bridge/work state, pending attachments, AirSend, recording, and shelf count without adding extra buttons.
- Expanded shelf shows saved screenshot/clip batches as clean piles that can be dragged out, previewed with Quick Look, AirDropped, copied, saved, or cleared.

**Quick Reference**
- "Quick Reference" in the menu bar pulls up a floating cheat sheet with all shortcuts and the VideoFrame Lab workflow.

## Shortcuts

| Action | Shortcut |
|---|---|
| Capture region (global) | Cmd+Opt+4 |
| Capture full screen (global) | Cmd+Opt+1 |
| Capture window (focused) | Cmd+Opt+2 |
| New board | Cmd+Opt+B |
| Delay capture | Timer menu in toolbar |
| Record selected-area video clip (global) | Cmd+Opt+5 |
| Copy annotated PNG | Cmd+C |
| Save annotated PNG | Cmd+S |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Cancel in-progress stroke | Esc |
| Pin to screen | Pin button in toolbar |
| Clear all pins | pin.slash button or menu bar |
| Quick Reference cheat sheet | Menu bar → Quick Reference |

## VideoFrame Lab Workflow

1. Hit Cmd+Opt+5, or Record in the toolbar/menu bar.
2. macOS recording UI opens in forced mouse-selection video mode — drag the rectangle you want, then start recording.
3. It records until you click Record again in Desk Agent.
4. When recording stops, the clip is added to Shelf and MarkShot shows a Send button.
5. Hit Send to upload the `.mov` to VideoFrame Lab. MarkShot starts `localhost:3000` or the next free port if needed and opens the imported job.
6. Pick frame density, paste any transcript notes, process, copy the AI motion brief or export the ZIP.
7. Use menu bar → Stop VideoFrame Lab when done, or let MarkShot auto-stop it after 30 idle minutes.

## Dragging the Toolbar

The toolbar is draggable when no screenshot is loaded. Click and drag the background of the capture strip to move it anywhere on screen. When a screenshot is loaded, dragging is disabled so the annotation canvas can receive mouse events.

## Permissions

- Screen Recording: required for all capture. Enable MarkShot in System Settings → Privacy & Security → Screen Recording if capture fails.
- Files and Folders: only through the native save panel.
- Clipboard: used for copy; no permission prompt.
- Accessibility: not required. Carbon hotkeys work without it.
- Local Network: VideoFrame handoff uses `http://localhost:3000` only.

## Run / Install

```bash
cd MarkShot
./script/build_and_run.sh --install
```

Installs to `/Applications/MarkShot.app`. If Screen Recording permission gets stuck after a rebuild:

```bash
tccutil reset ScreenCapture com.deskagent.MarkShot
open -n /Applications/MarkShot.app
```

## Build

```bash
swift build
```

## Smoke Render

Verifies annotation rendering, PNG export, and clipboard copy without needing Screen Recording:

```bash
.build/debug/MarkShot --smoke-render /tmp/markshot-permission-smoke.png --smoke-output /tmp/markshot-annotated-smoke.png
```

## Known Gaps

- Cmd+Shift+4 belongs to macOS — MarkShot uses Cmd+Opt+4 to avoid the conflict.
- Window capture is interactive (click to choose), not automatic active-window.
- Redact is a solid black box, not a blur.
- Global hotkeys cover Cmd+Opt+4, Cmd+Opt+1, and Cmd+Opt+5.
- Record Clip currently uses Apple's manual `screencapture -v` flow. MarkShot can send the resulting `.mov` to VideoFrame Lab, but it does not provide its own stop/timer UI yet.
- No recent tray, autosave history, GIF export, callout bubbles, loupe, or OCR.
