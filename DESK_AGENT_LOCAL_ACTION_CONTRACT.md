# Desk Agent Local Action Contract

Status: in progress. First helper contract and grounding skeleton are implemented and live on the local helper.

Purpose: make the Notch + helper the local Mac perception/action harness for Hermes, while Hermes stays the planner and memory-bearing agent.

Desk Agent should stay Notch-first, Apple-native, phone-aware, and Hermes-centered. One visible conversation control is always `Talk to Hermes` and there is one desktop app surface.

## Product Boundary

- **Hermes / outer agent**: long-horizon reasoning, planning, memory, web/files/research, routing between providers, and deciding what should happen next.
- **Desk Agent helper**: local Mac bridge, approved action execution, action history, live voice session state, iPhone/Notch transport, and future observe/ground/act APIs.
- **Notch app (Mac)**: primary desktop surface, `Talk to Hermes`, chat, shelf, screenshots, notes, approvals, and local computer-use visibility.
- **iPhone app**: companion surface for docked/remote use, Talk, Share Sheet intake, Shortcuts/widgets, and Handoff continuation.

Cross-surface truths:

- The Notch is the user-visible Mac surface for desk actions.
- Helper and iPhone are companion layers only.
- No second visible Mac companion app should be created or reintroduced.

## Rules

1. One local computer action per helper request.
2. Every request and response should carry a `trace_id`.
3. Observe and ground before any non-read action.
4. Ground visible targets before click/type actions.
5. Act only through approved drivers and allowlists.
6. Record the action result in helper history.
7. Validate after actions that are expected to change state.
8. Do not click password, payment, 2FA, consent, destructive, or credential-finalization controls automatically.
9. Prefer Apple-native primitives before custom transport or UI:
   - **AirDrop** for user file transfer
   - **Handoff** for conversation handoff
   - **App Intents / Shortcuts** for launch, status, and capture actions
   - **Quick Look** for local attachment preview
   - **Continuity Camera** for note/media capture
   - **Share Sheet** for normal app-to-app sharing
10. Keep provider routing swappable: Gemini Live, OpenAI Realtime, Hermes, hosted agents, or future local agents are adapters behind the same surface.
11. Do not leak helper/driver internals to end users; visible copy stays in Notch terms (`Talk to Hermes`, `action pending`, `approved`, `completed`, `blocked`).

## First Helper API Shape

Base helper URL remains:

```text
http://127.0.0.1:4177
```

Implemented local-only endpoints:

```text
GET  /api/local-action/contract
GET  /api/local-action/observe
GET  /api/local-action/ground
GET  /api/local-action/history
POST /api/local-action/act
```

`/act` starts conservatively with approved launchpad actions and dry-run/no-op planning only.

### Action-Driver Phases (next)

Phase 1, now (read-only):

- `/act` accepts only `dry_run_action`, launchpad/no-op planning, and `request_gated_action` review requests.
- `/ground` returns active app, top-level AX summary, browser context, optional read-only CDP DOM summaries, and Apple-native route suggestions.
- Live helper tools expose read-only observe/ground and review-only gated-action requests to provider sessions.
- No stateful action is allowed without explicit approval context.

Phase 2, next:

- Enable additional explicit-and-approved actuation drivers.
- Done for first Apple-native slice: `shortcuts` can run only helper-configured Apple Shortcut IDs.
- Done for second Apple-native slice: selected `appleScript` actions can run only helper-configured script IDs.
- Every act request still requires confirmability and per-surface traceability.
- Approving future gated local actions records approval first; execution stays disabled until that driver and validation path are implemented.

Phase 3, after gates:

- Enable click/type/scroll inputs (`cua` / `accessibility`) only behind explicit feature gates + user approvals.
- Keep each action one-at-a-time with strict validation.

## Request Shape

```json
{
  "trace_id": "hermes_1234abcd",
  "action": "run_launch_action",
  "actionId": "open-affinity",
  "validate_state_change": true
}
```

## Response Shape

```json
{
  "ok": true,
  "trace_id": "hermes_1234abcd",
  "status": "completed",
  "action": {
    "kind": "launchpad",
    "id": "open-affinity",
    "label": "Affinity"
  },
  "validation": {
    "performed": true,
    "method": "active-app-summary",
    "status": "requested"
  }
}
```

Dry-run request shape for Hermes planning without touching the Mac:

```json
{
  "trace_id": "hermes_1234abcd",
  "action": "dry_run_action",
  "intent": "click the first visible search result after grounding it"
}
```

Allowlisted Shortcut request shape:

```json
{
  "trace_id": "hermes_1234abcd",
  "action": "run_shortcut_action",
  "shortcutId": "desk-agent-status"
}
```

Allowlisted AppleScript request shape:

```json
{
  "trace_id": "hermes_1234abcd",
  "action": "run_applescript_action",
  "scriptId": "frontmost-app"
}
```

Gated-action request shape for future control without executing it:

```json
{
  "trace_id": "hermes_1234abcd",
  "action": "request_gated_action",
  "driver": "browser-dom",
  "intent": "click the first visible search result after grounding it",
  "target": "search result"
}
```

## Implementation Benchmarks

### Benchmark A: Contract And History

- Done: add `/api/local-action/contract`.
- Done: add `/api/local-action/observe` with helper/live/approval/active-app summary.
- Done: add `/api/local-action/ground` with active-app, AX summary, browser tab context, launch-action, Apple-native route, and pointer-bridge summaries.
- Done: add `/api/local-action/history` with trace-aware recent actions.
- Done: add `/api/local-action/act` for approved launchpad actions and no-op dry-run planning only.
- Done: local action history now includes compact structured details: status, driver, scope, action, result id/label/kind, dry-run flag, and validation summary.
- Done: AppleScript action history can include sanitized/truncated stdout so Hermes can see the result without receiving script source, and read-only scripts validate as `observed`.
- Done: contract, observe, ground, Realtime, and Live tool listings expose `readOnly` for approved AppleScript actions without exposing script source.
- Done: update helper tests.
- Done: restart helper and verify live `contract`, `observe`, `ground`, and `history` responses.

### Benchmark B: Driver Boundary

- Done: introduce a helper-side action driver model with `launchpad` as the first enabled driver.
- Done: add `noop` / `dry_run_action` as a traceable planning driver so Hermes can record intent before real control exists.
- Done: add `shortcuts` / `run_shortcut_action` for explicitly configured Apple Shortcut IDs only.
- Done: add `appleScript` / `run_applescript_action` for explicitly configured AppleScript IDs only; script contents are not exposed to provider tools.
- Done: configure the first production read-only AppleScript action, `frontmost-app`, on the helper. It reports the current frontmost app, advertises `readOnly: true`, and records safe output in the response/history with `applescript-output` validation.
- Done: add `review` / `request_gated_action` as an approval-queue driver. It can create and trace review items, but approval currently records intent without executing click/type/scroll.
- Done: expose local observe/ground/review through the Live tool surface so Gemini/Hermes can use the harness without gaining click/type/scroll execution.
- Near-term next drivers (explicitly gated):
  - expand `appleScript` only with small named read-only or Apple-native actions
  - add `shortcuts` only after the actual Shortcut exists on this Mac
  - `cua`
  - `accessibility`
  - `browser-dom`
- Keep arbitrary desktop control behind explicit capability flags and permissions.
- Gate every click/type/scroll driver behind an explicit approval mode.

### Benchmark C: Observe And Ground

- Done: observe active app/window title through the local helper.
- Done: expose the existing iPhone touchpad -> `DeskAgentPointer` bridge as an explicit opt-in pointer capability.
- Done: coarse `ground` endpoint returns active app, approved launch actions, and safety state.
- Done: add first System Events AX summary for top-level visible native controls.
- Done: add first browser context summary for frontmost Chrome/Safari-style tabs through AppleScript.
- Done: add read-only Chrome DevTools Protocol DOM target summary when a frontmost Chromium browser exposes local remote debugging.
- Next: add deeper AX tree summaries for nested native controls.
- Next: add browser DOM/CDP target summaries as a first-class browser driver behind capability gates.
- Add local screenshot/OCR/perception only after native AX/browser paths miss.

### Benchmark D: Act And Validate

- Click/type/shortcut/open/scroll actions run one at a time.
- Done for first driver: each local action writes `trace_id`, chosen driver result, and validation summary.
- Done for review driver: gated click/type/scroll/browser requests can enter the approval queue without executing.
- Done: history lookup by `trace_id` can recover the action driver and validation details for later Hermes/provider turns.
- Validate through active app/window changes, AX fingerprint, or visible state where practical.

### Benchmark E: Highlight Context

- Reuse MarkShot/shelf/Notes affordances for "this part" instead of adding a separate pointer product.
- A future focus highlight should resolve to one of:
  - selected text
  - screenshot region
  - local file/image
  - browser URL
  - visible UI element
- Hermes gets the resolved source and allowed tools.

### Benchmark F: Apple-Native Continuity

- Done: iPhone Share Sheet intake for text, links, single images.
- Done: Quick Look for shelf batches and local chat images.
- Done: Mac App Intents first pass, including open/shelf/talk/status intents with Notch companion flow.
- Done: Handoff bridge wiring, still needs physical proof.
- Next:
  - physical Handoff/Share Sheet proof with real UI passes
  - Continuity Camera in Notes (not chat), not as a local action control
  - quick status surfaces via Widgets/Live Activities after Talk status stabilizes
  - Spotlight/Core Spotlight for persisted notes/media search
  - keep AirDrop and Files for general transfer, not computer-use control

## What To Avoid

- Do not make a second visible Mac companion app.
- Do not make AirSend a file-transfer product; AirDrop/Files owns normal transfer.
- Do not put every mode on the Notch surface.
- Do not let Gemini/OpenAI own the product model. They are providers, not the app.
- Do not send multi-step open-ended plans into the local action harness.

## TipTour Notes Worth Keeping

- Their strongest idea is not the UI; it is the strict boundary between planner and local executor.
- Their action-driver protocol is the right pattern for CUA/AX/browser/AppleScript swapping.
- Their traceable one-action loop is the right safety model.
- Their focus-highlight/source resolver is worth adapting into MarkShot/Notes/Hermes context.
- Their local-first grounding order is good: AX, browser DOM, local perception/OCR, model coordinates last.
