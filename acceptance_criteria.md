# WalleBrain Native App Acceptance Criteria

## Scope
This document defines the first **real usable macOS desktop build** of WalleBrain.

This phase is accepted only if the native app can:

1. Launch as a real `.app` bundle with privacy usage descriptions
2. Edit the term dictionary inside the app
3. Start a real microphone meeting session
4. Save meeting audio locally
5. Stream live transcription into the meeting session
6. Stop the meeting and export a final Markdown note
7. Keep DeerAPI post-processing and speech-asset compilation working

## P0 Release Gates

### P0.1 Native Build And Bundle
- `swift build` succeeds for all native targets
- A bundled app is produced under `runtime/native/`
- The bundle `Info.plist` contains:
  - `NSMicrophoneUsageDescription`
  - `NSSpeechRecognitionUsageDescription`

### P0.2 Native App Workspace
- The bundled app launches into a native SwiftUI window
- The app exposes:
  - a meeting workspace
  - a term dictionary editor
  - an acceptance/harness area

### P0.3 Term Dictionary
- `Business Dictionary.md` is created if missing
- The dictionary is editable in-app
- Saving updates the backing markdown without restarting the app
- The dictionary still compiles into Apple speech customization assets

### P0.4 Real Meeting Session
- Starting a meeting creates:
  - a `.session.json`
  - a `.session.md`
  - a local audio recording file
- The selected input device is recorded in the session
- The default preferred input is `MacBook Pro麦克风` when available

### P0.5 Real-Time Speech Pipeline
- The native app uses Apple Speech framework live analysis APIs
- A microphone session can advance to `recording` state without crashing
- The real-time pipeline can be finalized cleanly on stop
- Transcript content may be empty during automated smoke, but the session must remain valid

### P0.6 Stop And Export
- Stopping a meeting moves the session to `exported`
- The exported note is written to the runtime Obsidian directory
- The note includes:
  - metadata
  - summary
  - key points
  - action items
  - live transcript
  - final transcript
  - dictionary path
  - audio path

### P0.7 DeerAPI And Speech Assets
- DeerAPI still works from native code using `DEERAPI_KEY` and `DEERAPI_BASE_URL`
- If shell env vars are absent from the app process, fallback loading from `.zshrc` works
- Speech customization assets still compile locally
- The dedicated speech probe still reaches `START_DONE` against fixture audio

### P0.8 Automated Acceptance
- Native acceptance exits `0`
- The acceptance report is written under `runtime/acceptance/native/`
- The report includes:
  - build status
  - bundle status
  - speech probe status
  - fixture harness note path
  - real meeting smoke session/note paths

## P1 Quality Gates

### P1.1 Failure Behavior
- Missing DeerAPI config fails clearly
- Invalid dictionary markdown fails clearly
- If no speech is captured, the app exports a note with a local empty-transcript summary instead of hallucinating content

### P1.2 Repeatability
- Running native acceptance repeatedly does not corrupt prior outputs
- New outputs are appended under deterministic runtime directories

### P1.3 Regression Coverage
- Fixture harness remains available for speech-asset and DeerAPI regression checks
- Real meeting smoke remains available for microphone/session/export regression checks

## Out Of Scope For This Phase
- System-audio capture
- Speaker diarization
- Multi-track recording
- Notarization and distribution packaging
- Perfect transcript accuracy benchmarking from automated microphone smoke

## Acceptance Command
- Pass condition: `swift run WalleBrainAcceptance` exits `0` and writes a fresh report under `runtime/acceptance/native/`
- Fail condition: any P0 gate above is missing or false
