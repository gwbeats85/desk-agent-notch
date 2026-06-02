# Desk Agent Bridge Protocol

Date: 2026-05-30

This is the stable product contract between the Notch app, iPhone app, helper, future server bridge, and future provider adapters.

The purpose is to keep Desk Agent provider-swappable. The UI should not care whether the active implementation is Gemini Live, OpenAI Realtime, Hermes, another hosted agent, or a future local agent.

## Surfaces

- `notch`: primary Mac desktop surface.
- `iphone`: docked or remote companion.
- `helper`: local M5 bridge/service layer.
- `server`: future always-on bridge/fallback.
- `agent`: active work/runtime adapter.

## Envelope

Every cross-surface event should fit this shape:

```json
{
  "type": "deskagent.status.v1",
  "source": "notch",
  "createdAt": "2026-05-30T00:00:00.000Z",
  "sessionId": "live-session-or-empty",
  "conversationId": "conversation-or-empty",
  "payload": {}
}
```

Required fields:

- `type`
- `source`
- `createdAt`
- `sessionId`
- `conversationId`
- `payload`

## Message Types

- `deskagent.status.v1`: helper/provider/agent capability status.
- `deskagent.chat.request.v1`: text or multimodal turn from a surface.
- `deskagent.chat.reply.v1`: assistant/work-agent reply.
- `deskagent.voice.start.v1`: request to start live voice.
- `deskagent.voice.stop.v1`: request to stop live voice.
- `deskagent.live.state.v1`: listening, thinking, speaking, blocked, offline.
- `deskagent.airsend.v1`: text/image/file handoff from iPhone or another surface.
- `deskagent.shelf.add.v1`: request to add an item to the Notch shelf.
- `deskagent.clipboard.write.v1`: explicit clipboard write request.
- `deskagent.switchboard.status.v1`: service/launch/action state.

## Provider Adapter Rule

Provider-specific details belong behind adapters:

- Gemini Live / Vertex
- OpenAI Realtime or ChatGPT-style live chat
- Hermes
- hosted agent runtime
- future local agent runtime

Shared UI should use neutral terms:

- live voice
- work agent
- agent bridge
- agent session
- tool handoff
- screen context
- media generation

## Current Helper Endpoints

Local helper:

`http://127.0.0.1:4177`

Remote helper:

`https://<mac>.ts.net/deskagent`

Current useful endpoints:

- `GET /api/health`
- `GET /api/live/config`
- `GET /api/notch/status`
- `POST /api/notch/airsend/:id/consume`
- `POST /api/voice/text`
- `POST /api/airsend`
- `POST /api/live/session/start`
- `POST /api/live/sessions/:id/transcript`
- `GET /api/live/socket`

## Conversation Identity

The shared `conversationId` is the lightweight thread key that lets Notch chat, Notch live voice, iPhone Talk, and future server/provider adapters point at the same user-facing conversation.

Current Notch behavior:

- Notch stores a persistent id in `@AppStorage("deskagent.notch.conversationId")`.
- The id is created lazily with the shape `notch-<uuid>`.
- Notch passes that id into the hidden live shell when starting live voice.
- The helper records it on `POST /api/live/session/start` sessions as `session.conversationId`.

Current rule:

- `conversationId` is not provider-specific.
- Hermes session ids and provider live session ids can change under it.
- iPhone Talk and shortcuts now send a persistent `conversationId` with `/api/voice/text`.
- Current phone ids use the shape `iphone-<uuid>`.
- The helper records recent text turns with `source`, `conversationId`, transcript, response, backend, and timestamp.
- Authenticated phone status now includes `live.activeSessions`.
- When the phone app refreshes status and sees an active live session with a `conversationId`, the next phone text turn uses that active Notch conversation id. If no active live session is present, it falls back to the persistent `iphone-<uuid>` id.
- The phone app also has a first-pass true Live path. Voice -> `Live` opens the helper `live-shell.html` in WebKit, injects the paired helper token, and starts the same `DeskAgentLive.start({ learnMode: false, interactionMode: "autopilot", conversationId })` call used by the Notch.
- Native phone `Talk` is still speech-to-text over `/api/voice/text`; phone `Live` is the streaming Gemini Live path.
- Product direction is one visible `Talk to Hermes` experience. Keep native speech-to-text and streaming Live as swappable implementation modes instead of permanent competing voice buttons.
- Native phone Live should preflight iOS microphone permission/audio-session setup before asking WebKit for `getUserMedia`.
- WebKit microphone capture should report `microphone_timeout` or `microphone_error` back to native UI when the browser view cannot open the mic, so manual phone tests do not stall at `requesting_microphone`.
- Current iPhone direction: do not use WebKit as the phone microphone source. The phone Live screen should use native `AVAudioEngine` capture and send the same `realtime_input.media_chunks` frames to the helper live WebSocket.
- The phone Voice room primary `Talk` control routes to native live voice when paired/reachable. Native speech-to-text remains a fallback/quick-text mode, not the primary voice product.
- The iPhone UI should say `Talk to Hermes` for the primary path. Terms like Gemini Live, native Live, socket, or transcript finalization are implementation details and should stay in diagnostics/docs instead of becoming separate user choices.
- `npm run live:socket:proof` verifies the helper live WebSocket/bootstrap contract. Run it sequentially with other live-session proofs because the helper intentionally treats the latest live session as the active one.
- Native iPhone Live must handle Gemini `toolCall.functionCalls` the same way the web live shell does: call helper `/api/live/tool`, then send `tool_response.function_responses` back over the live socket.
- `npm run live:tool:proof` verifies the helper live tool endpoint contract used by native and web live clients.
- Native iPhone live clients can post `POST /api/live/sessions/:id/diagnostic` milestones such as `session_started`, `setup_complete`, `mic_frame`, and transcript reports. `/api/notch/status` exposes the latest active-session diagnostic so manual phone tests can tell whether the failure is route, mic, socket, or transcript finalization.
- The Notch should persist the last imported helper conversation turn id. It should not treat the first status refresh as a reason to discard unseen phone-origin turns.
- Synthetic proof turns with proof conversation ids should be filtered out before Notch UI/chat import, even though the helper still records them as valid proof evidence.
- Live session starts now also carry a surface `source`. Current values are `notch` and `iphone`; helper/status records preserve this so either surface can tell where the active live session came from.
- `live-shell.html` supports `window.DeskAgentLiveDefaults` with `source`, `interactionMode`, and `conversationId`. Native hosts should set those defaults before page controls can start a session, so visible web-shell buttons do not create blank conversation ids.
- Final live user/assistant transcripts should be reported back to the helper through `POST /api/live/sessions/:id/transcript`.
- The helper pairs those final transcript events into shared `conversation.recentTurns` as `actionKind: "live-voice"`, using the live session `source` and `conversationId`.
- A later manual join/claim UI can make this behavior more explicit, but the basic active-session join path is now wired.

## Notch Status Payload

`GET /api/notch/status` is local-loopback only. It is for the primary desktop app to read bridge state without borrowing an iPhone pairing token.

`POST /api/notch/airsend/:id/consume` is also local-loopback only. The Notch calls it after a successful AirSend import so already-imported items do not keep appearing as waiting.

Expected shape:

```json
{
  "ok": true,
  "helper": {
    "startedAt": "2026-05-30T00:00:00.000Z",
    "nativeNearby": "bonjour-advertised"
  },
  "pairedDevices": 1,
  "pendingApprovals": 0,
  "recentActions": [],
  "airSends": [],
  "live": {
    "provider": "gemini",
    "model": "gemini-live-2.5-flash-native-audio",
    "activeSessions": [
      {
        "id": "live_example",
        "provider": "gemini",
        "model": "gemini-live-2.5-flash-native-audio",
        "source": "iphone",
        "conversationId": "notch-example",
        "startedAt": "2026-05-30T00:00:00.000Z"
      }
    ],
    "conversation": {
      "recentTurns": [
        {
          "id": "turn_example",
          "source": "iphone",
          "conversationId": "iphone-example",
          "text": "status",
          "response": "Helper is online.",
          "backend": "helper-local",
          "actionKind": "voice-text",
          "at": "2026-05-30T00:00:00.000Z"
        }
      ]
    },
    "readiness": {
      "level": "ready"
    }
  }
}
```

## Capability Truth

The bridge should report what is available now:

- Mac local actions available only when the M5 helper is reachable.
- Screen capture available only when the active Mac grants permission.
- Clipboard writes must stay explicit.
- Server fallback may answer/chat when M5 is off, but Mac-local actions should be unavailable or queued.
- Remote iPhone mode should prefer saved Tailscale URL when Bonjour is not nearby.
- Helper status should expose bridge reachability truth:
  - LAN URLs the helper believes are usable from the phone
  - the recommended current LAN bridge URL
  - remote/Tailscale availability and reason
  - a remote save URL only when it is actually available
