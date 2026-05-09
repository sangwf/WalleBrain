# WalleBrain

WalleBrain is a native macOS meeting workspace for live transcription and post-processed meeting notes.

It currently focuses on:
- live transcription with Apple Speech APIs
- optional high-quality live transcription through OpenAI Realtime when `OPENAI_API_KEY` is set
- microphone / system-audio / mixed capture
- structured meeting notes generated through a configurable OpenAI-compatible LLM endpoint
- an editable term dictionary for company- or domain-specific vocabulary
- Markdown export to an Obsidian-style directory layout

## Status

This repository is an active prototype, not a notarized release build.

What works today:
- start a meeting from the native desktop app
- stream live transcript into the workspace
- stop and generate:
  - `Summary`
  - `Organized Transcript`
  - `Key Points`
  - `Action Items`
- copy transcript / notes from the UI
- edit model settings from the app

Current distribution limitation:
- the bundled `.app` is suitable for local use and technical testing
- it is not yet signed with a public Apple Developer identity or notarized for wide distribution

## Requirements

- macOS 26 or later
- Swift 6.2 toolchain
- microphone permission for live meetings
- Screen & System Audio Recording permission if you want system audio capture
- `OPENAI_API_KEY` if you want High Quality realtime transcription
- an OpenAI-compatible chat completions endpoint for post-processing

## Quick Start

### 1. Configure the LLM endpoint

You can configure the app either from environment variables or inside the app settings. Settings fields accept either literal values or `$ENV_VAR` references.

Example environment variables:

```bash
export WALLEBRAIN_LLM_BASE_URL="https://api.openai.com/v1"
export WALLEBRAIN_LLM_API_KEY="your-api-key"
export WALLEBRAIN_LLM_MODELS="gpt-4.1-mini"
```

You can also open `Settings` in the app and set:
- `Base URL`
- `API Key`
- `Models`
- `Provider Label`

`Models` supports:
- a single model: `gpt-4.1-mini`
- an ordered fallback chain: `gpt-4.1-mini, gpt-4.1`

If a setting starts with `$`, WalleBrain resolves it as an environment variable. Otherwise, the setting is used as a literal value. The app expects an OpenAI-compatible `/chat/completions` API; if the base URL ends at `/v1`, WalleBrain appends `/chat/completions` automatically.

### Optional: High Quality realtime transcription

The meeting controls include a `Local / High Quality` transcription mode.

- `Local` uses Apple Speech and keeps live transcription on-device.
- `High Quality` streams live meeting audio to OpenAI Realtime and reads the API key from `OPENAI_API_KEY`.
- The input meter shows `Idle`, `Weak`, `Quiet`, or `Audio` so you can confirm the selected audio source is active before relying on live transcription.

```bash
export OPENAI_API_KEY="your-openai-api-key"
```

The default realtime transcription model is `gpt-realtime-whisper`. If OpenAI publishes a dated model id, override it without changing app settings:

```bash
export WALLEBRAIN_REALTIME_TRANSCRIPTION_MODEL="gpt-realtime-whisper"
```

High Quality mode sends live audio to OpenAI and applies upload-side gain for weak microphone input. Use `Local` when you want fully on-device live transcription or when network reliability is more important than cloud transcription quality.

### 2. Run tests

```bash
swift test
```

### 3. Build the app bundle

```bash
./scripts/build_native_bundle.sh WalleBrainApp WalleBrain com.wallebrain.app
```

### 4. Open the app

```bash
open runtime/native/WalleBrain.app
```

## Repository Layout

### Native app

- [`Package.swift`](Package.swift)
- [`Sources/WalleBrainApp`](Sources/WalleBrainApp)
- [`Sources/WalleBrainCore`](Sources/WalleBrainCore)
- [`Tests/WalleBrainCoreTests`](Tests/WalleBrainCoreTests)

### Supporting artifacts

- [`acceptance_criteria.md`](acceptance_criteria.md)
- [`spec.md`](spec.md)
- [`fixtures/datasets`](fixtures/datasets)

### Legacy web harness

These files are kept as historical prototype code and are not the main product path anymore:

- [`src/`](src)
- [`package.json`](package.json)
- [`vite.config.ts`](vite.config.ts)

## Privacy / Data Flow

- live speech recognition is performed locally through Apple speech APIs
- High Quality live transcription sends meeting audio to OpenAI Realtime
- meeting audio is saved locally under `runtime/`
- post-processing sends transcript text, not raw audio, to the configured LLM endpoint

## Recovery Behavior

If WalleBrain quits unexpectedly during a meeting, the next launch marks interrupted `preparing`, `recording`, or `processing` sessions as `failed` instead of treating them as still running. Partial transcript and audio files are preserved, and failed post-processing can be retried from the app when transcript text exists.

## Roadmap Gaps

Before this should be treated as a broadly installable public app, it still needs:
- public Apple Developer signing
- notarization
- first-run permission polish on a clean machine
- more hardening around system-audio capture across machines

## License

MIT. See [`LICENSE`](LICENSE).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).
