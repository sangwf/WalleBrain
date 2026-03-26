# Harness Plan v0.1

## Goal

Build a replaceable, verifiable end-to-end harness for the meeting assistant before integrating real system, audio, and model capabilities.

The first harness must prove one thing:

**A meeting session can start, produce live artifacts, finish, run post-processing, and export a final note.**

---

## 1. Golden Path

The first runnable path is:

1. User triggers `start meeting`
2. System creates `session.md` and `session.json`
3. Live text appears in the session document
4. Audio artifact is created and attached to the session
5. User triggers `end meeting`
6. Post-processing runs
7. Final note is exported to the Obsidian target path

This golden path is more important than real Dictation, real recording, or real Gemini integration in the first pass.

---

## 2. Harness Principles

1. **One path first**
   No branching flows before the default path is reliable.

2. **Session-centered design**
   All modules read from or write to the session contract.

3. **Fake first, real later**
   Early modules should simulate production behavior while preserving future interfaces.

4. **Stable file contracts**
   The session files and final note format must stabilize early.

5. **Swap, not rewrite**
   Real implementations must replace fake ones behind the same interfaces.

---

## 3. Proposed Repository Shape

This is a suggested initial structure, not a final mandate:

```text
src/
  meeting/
    session/
      session-types.ts
      session-store.ts
      session-markdown.ts
    launcher/
      session-launcher.ts
    dictation/
      dictation-bridge.ts
      fake-dictation-bridge.ts
    recorder/
      recorder.ts
      fake-recorder.ts
    postprocess/
      post-processor.ts
      fake-post-processor.ts
    export/
      note-exporter.ts
    orchestration/
      meeting-orchestrator.ts
    ui/
      MeetingSessionShell.tsx
      SessionHeader.tsx
      LiveTranscriptPanel.tsx
      SessionSidebar.tsx
```

---

## 4. Core Session Contracts

### 4.1 `session.md`

Purpose:

- human-readable live workspace
- target for live Dictation text
- agent scratchpad during the meeting

Suggested structure:

```markdown
# {{title}}

## Session Meta
- Session ID: {{session_id}}
- Started At: {{started_at}}
- Mode: {{mode}}
- Status: {{status}}

## Live Transcript (Reference Only)
{{live_transcript}}

## Interim Notes
{{interim_notes}}

## Open Questions
{{open_questions}}

## Interim Action Items
{{interim_action_items}}
```

### 4.2 `session.json`

Purpose:

- machine-readable source of truth
- state transitions
- artifact registry
- orchestration input

Suggested shape:

```json
{
  "id": "2026-03-25T10-30-00Z_product-review",
  "title": "Product Review",
  "mode": "normal",
  "status": "created",
  "startedAt": "2026-03-25T10:30:00Z",
  "endedAt": null,
  "paths": {
    "sessionMarkdown": "WalleBrain/MeetingSessions/2026/...session.md",
    "audioFile": null,
    "finalNote": null
  },
  "features": {
    "dictationEnabled": true,
    "agentEnabled": true,
    "recordingEnabled": true
  },
  "processing": {
    "transcriptStatus": "pending",
    "summaryStatus": "pending",
    "exportStatus": "pending"
  },
  "artifacts": {
    "liveTranscriptChunks": [],
    "transcript": null,
    "summary": null,
    "keyPoints": [],
    "actionItems": []
  },
  "errors": []
}
```

### 4.3 Final note

Purpose:

- long-term meeting record
- exported Obsidian artifact
- editable knowledge object

Minimum sections:

- summary
- key points
- action items
- transcript

---

## 5. State Machine

The harness should enforce this state flow:

1. `created`
2. `recording`
3. `recorded`
4. `transcribing`
5. `summarized`
6. `exported`
7. `failed`

Rules:

- `recording` starts only after session files exist
- `recorded` means the audio artifact is finalized
- `transcribing` begins only after `recorded`
- `summarized` requires transcript output to exist
- `exported` means the final note path was written successfully
- any state may transition to `failed`, but prior artifacts must remain on disk

---

## 6. Module Boundaries

### 6.1 Session Launcher

Inputs:

- trigger event
- optional title/mode metadata

Outputs:

- initialized session files
- initial UI state

Interface sketch:

```ts
type SessionLauncher = {
  createSession(input: CreateSessionInput): Promise<MeetingSession>;
};
```

### 6.2 Dictation Bridge

Inputs:

- session id
- append target

Outputs:

- live transcript chunks
- status updates

Interface sketch:

```ts
type DictationBridge = {
  start(session: MeetingSession): Promise<void>;
  stop(sessionId: string): Promise<void>;
  onChunk(cb: (chunk: LiveChunk) => void): Unsubscribe;
};
```

### 6.3 Recorder

Inputs:

- session id
- audio mode/config

Outputs:

- audio file path
- recording lifecycle events

Interface sketch:

```ts
type Recorder = {
  start(session: MeetingSession): Promise<void>;
  stop(sessionId: string): Promise<AudioArtifact>;
};
```

### 6.4 Post Processor

Inputs:

- audio artifact
- session metadata
- processing mode

Outputs:

- transcript
- summary
- key points
- action items

Interface sketch:

```ts
type PostProcessor = {
  run(session: MeetingSession): Promise<PostProcessResult>;
};
```

### 6.5 Note Exporter

Inputs:

- session state
- post-processing result

Outputs:

- final note path

Interface sketch:

```ts
type NoteExporter = {
  export(session: MeetingSession, result: PostProcessResult): Promise<ExportResult>;
};
```

### 6.6 Meeting Orchestrator

Responsibilities:

- coordinate module execution
- persist state transitions
- centralize retries and failure handling

This should become the harness backbone.

---

## 7. Fake Implementations For Harness v0.1

### 7.1 Fake Dictation Bridge

Behavior:

- appends canned transcript lines into `session.md`
- emits one chunk every 1-2 seconds
- marks chunks as reference-only

Purpose:

- proves live UI updates
- proves session markdown append behavior

### 7.2 Fake Recorder

Behavior:

- creates a placeholder `.m4a` file
- records timestamps in `session.json`
- returns a predictable artifact path on stop

Purpose:

- proves artifact creation
- proves session finalization flow

### 7.3 Fake Post Processor

Behavior:

- reads `session.md`
- combines canned text with session metadata
- emits synthetic transcript, summary, key points, and action items

Purpose:

- proves the post-meeting pipeline
- proves final note export and formatting

### 7.4 Fake Export Validation

Behavior:

- writes a final `.md` note
- verifies required sections are present

Purpose:

- proves Obsidian output shape before real integration hardening

---

## 8. UI Harness Scope

The first UI only needs these surfaces:

### 8.1 Meeting Session Shell

- title
- timer
- state pills
- primary action button

### 8.2 Live Transcript Panel

- appends incoming chunks
- visibly marked as reference-only

### 8.3 Working Sections

- interim notes
- open questions
- interim action items

### 8.4 Sidebar

- session state
- current artifact paths
- processing mode
- last update timestamp

This is enough to validate workflow without building the final polished product.

---

## 9. Milestone Order

### Milestone 1: Session Skeleton

Deliver:

- create session command
- write `session.md`
- write `session.json`
- render minimal meeting shell

Acceptance:

- user can start a session and see a session id, title, and created state

### Milestone 2: Fake Live Flow

Deliver:

- fake Dictation bridge
- live transcript append loop
- session state updates to `recording`

Acceptance:

- session view updates live without manual refresh

### Milestone 3: Fake Closeout Flow

Deliver:

- fake Recorder output
- end meeting action
- state transition to `recorded`

Acceptance:

- ending the meeting creates a stable audio artifact path and closes live updates

### Milestone 4: Fake Post-Processing

Deliver:

- fake post-processor
- transcript/summary/key points/action items generated
- state transitions through `transcribing` and `summarized`

Acceptance:

- session can produce complete structured meeting outputs from the fake pipeline

### Milestone 5: Export Path

Deliver:

- note exporter
- final Obsidian markdown note
- state transition to `exported`

Acceptance:

- a complete final note exists at the target path with all required sections

### Milestone 6: Swap First Real Dependency

Deliver:

- replace fake post-processor with real Gemini-based post-processing

Acceptance:

- exported note is generated from real model output without changing upstream UI or orchestration contracts

---

## 10. Acceptance Criteria For Harness v0.1

The harness is successful when all of the following are true:

1. A session can be started from one trigger
2. Session files are created deterministically
3. Live content appears in the UI and in `session.md`
4. Ending the session finalizes artifacts and advances state
5. Post-processing produces structured outputs
6. A final note is exported to the target location
7. Re-running failed post-processing does not require recreating the session

---

## 11. Recommended Immediate Next Tasks

1. Implement `session-types.ts` and `session-store.ts`
2. Implement `meeting-orchestrator.ts`
3. Create fake Dictation, Recorder, and Post Processor modules
4. Build the minimal session shell UI
5. Add one end-to-end harness command or button that runs the golden path

---

## 12. What Not To Do Yet

Do not start with:

- real macOS Dictation automation
- real audio capture edge cases
- diarization
- multi-session knowledge graph features
- complex UI polish
- aggressive model prompt tuning

Those are second-order concerns until the harness proves the core loop.
