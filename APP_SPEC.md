# App Spec

## Current Product Note

This spec describes the original **MarkShot screenshot module**. It is still useful for preserving capture, annotation, shelf, board, and VideoFrame Lab behavior.

The current product direction is **Desk Agent for Mac**, with this app as the primary Notch desktop surface. Read these before using this spec for new work:

- `AGENTS.md`
- `CONTEXT.md`
- `TASKS.md`

## App Name

MarkShot

## Goal

A lightweight local macOS floating screenshot annotation app for AI/design work. Keep a compact toolbar on screen, capture a screen, region, or window, drop the capture into a macOS-style floating thumbnail stack, then open the editor only when the thumbnail is clicked.

## User Workflow

1. Open MarkShot.
2. Capture full screen, selected region, or selected window.
3. MarkShot hides during capture, then leaves a small floating thumbnail in the lower-right corner.
4. Multiple captures stack upward like macOS screenshot thumbnails.
5. Click a thumbnail to open the annotation editor, or hover it to copy/dismiss without opening the editor.
6. Use the bottom toolbar to add arrows, boxes, circles, pen marks, text labels, or redact boxes.
7. Copy the annotated image to the clipboard by default, save it as PNG when needed, or drag the PNG out of the app.

## Platform

- macOS app
- native SwiftUI shell with AppKit canvas and native macOS APIs

## MVP

- Screenshot capture using native `CGDisplayCreateImage` for full screen and macOS `screencapture -s` / `screencapture -w` for selected region and window capture.
- Menu bar status item for capture actions, showing the toolbar, hiding the toolbar, and quitting.
- Compact floating toolbar before capture.
- macOS-style floating thumbnail stack after capture; editor opens only when a thumbnail is clicked.
- Menu bar New Board action with a simple dot-grid free board for quick visual explanations.
- Tools: pointer, arrow, rectangle/highlight box, ellipse, freehand pen, text label, redact box.
- Board-only quick layout blocks: header, card, tag, button, input.
- Record Clip entry point using native `screencapture -v`, saving a local `.mov` and revealing it in Finder after the recording ends.
- Undo, redo, clear annotations.
- Color defaults: red, yellow, black, white.
- Stroke width control.
- Copy rendered PNG to clipboard.
- Save rendered PNG to a chosen location.
- Drag rendered PNG out of the app.
- Hide to menu bar with the toolbar X, and hide after successful copy or save.
- Native app hotkeys: Cmd+Option+4 for selected region and Cmd+Option+1 for full screen.
- Native app hotkey: Cmd+Option+B for a new free board.

## Out Of Scope

- Cloud sync, login, telemetry, analytics, accounts.
- Full design-editor features.
- MarkShot-managed screen recording controls, GIF export, OCR, recent tray, and autosave history.
- True active-window capture without user interaction.
- Configurable global hotkey in the first prototype.

## Permissions

- Permission: Screen Recording
- Why: macOS requires it for screenshots and video recording outside MarkShot's own windows.
- When requested: The first time a capture or record command runs, macOS may prompt or require enabling MarkShot in System Settings -> Privacy & Security -> Screen & System Audio Recording.

- Permission: Clipboard
- Why: Copy annotated PNG output.
- When requested: Clipboard writes do not usually show a permission prompt.

- Permission: Files and Folders
- Why: Save PNGs where the user chooses.
- When requested: Save panel is shown on export; persistent folder access is not used.

- Permission: Accessibility / Input Monitoring
- Why: Only needed later for lower-level key capture, configurable global hotkeys, or active-window automation.
- When requested: Not requested in the MVP. The current native hotkeys use Carbon app hotkeys and avoid Accessibility.

## Data & Storage

- settings: in-memory for MVP.
- files: only saved PNGs selected by the user and temporary drag/capture files in the system temp directory.
- history: none.

## Export / Sharing

- clipboard: Cmd+C copies the rendered annotated PNG.
- drag/drop: toolbar drag chip exports the rendered annotated PNG as a temporary file provider.
- file save: Cmd+S opens a save panel and writes PNG.
- share sheet: not included in MVP.

## UI Notes

Minimal floating overlay plus menu bar control. Before capture, show only a compact capture strip. The toolbar can be hidden to the menu bar while global hotkeys stay active. After capture or New Board, show the canvas itself with a tight bottom toolbar. Clipboard-first output; successful copy/save hides the overlay.

## Verification

- build command: `swift build`
- run command: `./script/build_and_run.sh --verify`
- smoke render command: `.build/debug/MarkShot --smoke-render /tmp/markshot-permission-smoke.png --smoke-output /tmp/markshot-annotated-smoke.png`
- manual test: launch app, grant Screen Recording permission, capture a screenshot, add an arrow, copy PNG, save PNG, and confirm output file exists.

## Handoff Notes

Document exact permissions, files changed, commands run, build/run result, working features, missing features, and next step.
