# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WalleBrain is a macOS meeting assistant that captures audio, provides live transcription via Apple Speech framework, and generates post-meeting notes (summary, key points, action items) using LLM APIs. Final notes are exported as Obsidian-compatible markdown.

The system has two parallel implementations:
- **TypeScript harness** (`src/`): CLI tools for session management, evaluation, and a Vite-based dev UI
- **Native Swift app** (`Sources/`): macOS SwiftUI app with real audio capture, on-device speech recognition, and global hotkey (double-tap Ctrl)

## Commands

### TypeScript (Node/tsx)

```bash
npm run typecheck                # Type-check TypeScript (tsc --noEmit)
npm run run-harness              # Run fake meeting harness end-to-end
npm run run-harness -- --processor real  # Run with real LLM post-processing
npm run create-session           # Create a meeting session
npm run eval-dataset             # Evaluate transcript quality against dataset
npm run acceptance-check         # Run acceptance criteria checks
npm run dev                      # Start Vite dev server (React UI + session API)
npm run build                    # Vite production build
```

### Native Swift (macOS 26+, Swift 6.2)

```bash
swift build                      # Build all Swift targets
swift test                       # Run WalleBrainCoreTests
swift run WalleBrainApp          # Run the native app from CLI
swift run WalleBrainAcceptance   # Run native acceptance tests
npm run native:bundle            # Code-sign and bundle WalleBrainApp as .app
npm run native:open              # Bundle and open WalleBrainApp
```

## Architecture

### Meeting Pipeline (both TS and Swift follow this flow)

```
Session Create → Recording → Live Transcription → Stop → Post-Processing → Export
  (created)      (recording)                       (recorded) (transcribing)  (exported)
                                                               → summary
                                                               → keyPoints
                                                               → actionItems
```

### TypeScript Layer (`src/`)

- `src/meeting/orchestration/meeting-orchestrator.ts` — Central coordinator. Wires together launcher, recorder, dictation, post-processor, and exporter. Manages session state transitions.
- `src/meeting/session/session-types.ts` — All TypeScript types for sessions, artifacts, and processing state.
- `src/meeting/session/session-store.ts` — Persists session JSON to disk.
- `src/meeting/postprocess/post-processor-factory.ts` — Creates fake or real LLM post-processor based on env vars or `--processor` flag.
- `src/meeting/llm/llm-chat-client.ts` — OpenAI-compatible chat completion client.
- `src/meeting/export/note-exporter.ts` — Generates final Obsidian markdown from session + post-process results.
- `src/meeting/recorder/` — Recorder interface with fake (fixture-based) and real (ffmpeg/avfoundation) implementations.
- `src/meeting/dictation/` — Dictation bridge interface with fake implementation.
- `src/bin/` — CLI entry points (each run via `tsx`).
- `src/ui/` — React components for the dev dashboard (served by Vite).
- `src/dev/session-dev-bridge.ts` — Vite middleware providing `/api/` endpoints for the dev UI.

### Native Swift Layer (`Sources/`)

- `WalleBrainCore` — Shared library: models, audio capture, speech recognition, LLM client, note export.
  - `LiveMeetingCoordinator.swift` — Actor orchestrating the full meeting lifecycle (permissions, capture, transcription, summarization, export).
  - `MicrophoneCaptureService.swift` / `SystemAudioCaptureService.swift` / `MixedCaptureService.swift` — Three audio capture modes (mic-only, system audio, mixed).
  - `TranscriptAssembler.swift` — Merges overlapping speech recognition chunks into clean transcript.
  - `LLMChatClient.swift` — OpenAI-compatible LLM summarization using the configured `Models` list from settings, tried from left to right.
  - `CustomLanguageModelCompiler.swift` / `TermDictionaryStore.swift` — Custom vocabulary for improving domain-specific speech recognition.
  - `NoteExporter.swift` — Generates Obsidian markdown with frontmatter.
  - `Models.swift` — All Swift model types (`NativeMeetingSession`, `MeetingMode`, `MeetingStatus`, etc.).
- `WalleBrainApp` — SwiftUI app entry point with `GlobalHotkeyController` (double-tap Ctrl) and `AppModel`.
- `WalleBrainSpeechProbe` — Standalone speech recognition probe for testing.
- `WalleBrainAcceptance` — Acceptance test runner.
- `WalleBrainRealMeetingSmoke` — Smoke test with real meeting audio.

### Runtime Data (`runtime/`)

Session files, audio recordings, exported notes, and evaluation datasets are stored under `runtime/` (gitignored). Structure:
- `runtime/WalleBrain/MeetingSessions/{year}/` — Session JSON and markdown
- `runtime/WalleBrain/MeetingAudio/{year}/` — Audio files (.m4a)
- `runtime/Obsidian/Meetings/{year}/` — Exported meeting notes
- `runtime/datasets/` — Evaluation audio datasets

## Key Environment Variables

- `WALLEBRAIN_LLM_API_KEY` — API key for the configured OpenAI-compatible LLM endpoint
- `WALLEBRAIN_LLM_BASE_URL` — Base URL for the configured OpenAI-compatible endpoint
- `WALLEBRAIN_LLM_MODELS` — comma-separated model fallback chain
- `WALLEBRAIN_LLM_PROVIDER_LABEL` — optional label used in exported metadata

These can be provided as shell environment variables or referenced from the native app settings with `$ENV_VAR`. The Swift layer also loads simple exported values from the user's shell profile via `ShellEnvironmentLoader`.

## Design Principles

- Audio files are the highest-priority artifact — never lose recordings even if transcription/summarization fails
- Session state is persisted after every transition so processing can resume from any point
- Fake implementations exist for all external dependencies (recorder, dictation, post-processor) to enable offline development and testing
- The TS harness and Swift app share the same runtime directory structure and session schema concepts but are not directly coupled
