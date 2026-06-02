# Desk Agent Paths

This file documents public-safe paths and configurable local settings.

## Source

- Mac app source: this repository root.
- Swift package name: `MarkShot` for now.
- Installed app name: `MarkShot.app` for now.

## Local Configuration

The app avoids publishing user-specific paths. Use these environment variables or app settings for local customization:

- `DESK_AGENT_SOURCE_PATH`
- `DESK_AGENT_APPS_PATH`
- `DESK_AGENT_NOTES_PATH`
- `DESK_AGENT_OBSIDIAN_INBOX`
- `DESK_AGENT_OBSIDIAN_VAULT`
- `DESK_AGENT_SERVICES_YAML`
- `DESK_AGENT_MUSIC_SERVER_URL`
- `DESK_AGENT_N8N_URL`
- `DESK_AGENT_GLANCE_URL`
- `DESK_AGENT_SKILLS_REFERENCES`
- `MARKSHOT_VIDEOFRAME_LAB_PATH`

## Installed App

- Primary install: `/Applications/MarkShot.app`
- Fallback user install: `~/Applications/MarkShot.app`

The installed/bundle names may remain MarkShot until a deliberate rename pass. Product docs and agent instructions should still call the current product Desk Agent.
