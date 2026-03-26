# macOS Hotkey Agent

This agent listens for a real `double Control` gesture on macOS.

The intended flow is:

1. Put the caret inside WalleBrain's editable `实时录写` area
2. macOS receives your physical `double Control` and starts Dictation into that field
3. WalleBrain receives the same gesture and starts a live recording session

The agent does **not** try to fake Dictation. It passively listens for the same hotkey and calls the local WalleBrain API.

## Run

Start the local app/dev server first:

```bash
npm run dev
```

In another terminal, run the hotkey agent:

```bash
npm run hotkey-agent
```

For a one-shot integration test without pressing keys:

```bash
swift macos/wallebrain_hotkey_agent.swift --once
```

## Optional environment variables

```bash
WALLEBRAIN_API_BASE=http://127.0.0.1:4173/
WALLEBRAIN_HOTKEY_MODE=normal
WALLEBRAIN_TITLE_PREFIX=会议记录
```

## Permissions

The first run may prompt for Accessibility permission because the agent listens for global modifier-key changes.

## Current behavior

- `double Control` starts a live WalleBrain session
- the `实时录写` panel is an editable field so macOS Dictation has a real text target
- request payload sets `dictationEnabled: true`
- if a live session is already recording, the hotkey trigger is ignored
