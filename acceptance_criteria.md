# WalleBrain Acceptance Criteria v0.2

## Scope

This document defines the next acceptance bar for WalleBrain as a **meeting-first second brain**.

This phase is accepted only if WalleBrain can do all of the following:

1. Run as a usable native macOS app for real meeting capture
2. Produce a structured first draft that is better than a flat summary
3. Support reviewable post-meeting feedback and targeted regeneration
4. Preserve meeting outputs as durable local artifacts
5. Extract cross-meeting project continuity signals instead of treating every meeting as isolated
6. Verify the above with repeatable automated harnesses and fixture-based evaluation

This document supersedes the earlier acceptance bar that focused mainly on "native app exists and can export a note."

---

## Product Acceptance Target

The target for this phase is not "perfect AI notes."

The target is:

**WalleBrain produces a trustworthy first draft, lets the user improve it through structured review, and preserves enough structure for project memory to compound across meetings.**

---

## P0 Release Gates

All P0 gates must pass.

### P0.1 Native App And Real Meeting Path

- `swift build` succeeds for all native targets
- A launchable `.app` bundle is produced under `runtime/native/`
- The app can:
  - create a meeting session
  - capture local meeting artifacts
  - stop and process a meeting
  - export a Markdown note
- The core meeting path remains local-first:
  - session JSON persisted
  - session Markdown persisted
  - audio artifact persisted when the input mode requires audio

### P0.2 Structured First Draft

After meeting post-processing completes, the session and exported note must contain at minimum:

- `summary`
- `organizedTranscript`
- `keyPoints`
- `actionItems`
- `decisions`
- `openLoops`
- `risks`
- `projectLinks`

Pass condition:

- these fields are present in the in-memory session model
- persisted in the session JSON
- rendered into the exported Markdown note

### P0.3 Information-Layer Preservation

WalleBrain must preserve multiple layers instead of collapsing everything into one output.

For an accepted meeting session, these layers must remain available:

- raw/live transcript
- corrected transcript
- organized transcript
- structured note output

Pass condition:

- a processed session can be reloaded from disk and still expose all preserved layers
- exported notes still include both readable synthesis and transcript evidence

### P0.4 Interactive Review Persistence

WalleBrain must support persisted review artifacts, even if the first UI iteration is minimal.

Minimum required persistent objects:

- `ReviewComment`
- `RevisionRequest`

Pass condition:

- review comments can be attached to a meeting session
- revision requests can be attached to a meeting session
- both survive encode/decode round-trip via session JSON

### P0.5 Project Continuity Signals

Meetings must no longer be purely isolated notes.

Minimum required project continuity structures:

- `ProjectReference`
- `MeetingProjectLink`

Pass condition:

- a meeting can persist one or more linked projects
- each link stores:
  - role (`primary` / `secondary` / `mentioned`)
  - status (`unresolved` / `confirmed` / `rejected`)
  - confidence
  - optional evidence

### P0.6 Backward Compatibility

Existing saved sessions must continue to load after the model expansion.

Pass condition:

- a legacy session JSON that lacks the new memory fields still decodes successfully
- missing new fields default safely without corrupting the session

### P0.7 Automated Acceptance Report

The acceptance runner must produce a machine-readable report under `runtime/acceptance/native/`.

The report must include:

- build/bundle status
- real-meeting smoke status
- structured-output status
- backward-compat decode status
- review-model round-trip status
- note export status
- fixture-eval status

---

## P1 Quality Gates

These are required for this phase even if some are evaluated using deterministic fixtures rather than full live meetings.

### P1.1 Structured Output Quality On Fixtures

WalleBrain must pass a fixture-based note-quality suite.

The fixture suite must include at least:

- one meeting with an explicit decision
- one meeting with explicit follow-up actions
- one meeting with tentative language that should remain tentative
- one meeting with no real action items
- one meeting referencing a known project across multiple sessions

For each fixture, the acceptance spec must define expected outputs or expected invariants.

Minimum invariants:

- explicit decisions must appear under `decisions`
- explicit follow-ups must appear under `actionItems` and/or `openLoops`
- transcripts with no explicit commitments must not hallucinate strong action items
- tentative source language must not be rewritten as certainty
- tentative/background transcripts that never reach an explicit commitment must not hallucinate `decisions`
- project references must either:
  - link to the correct known project, or
  - remain explicitly unresolved

### P1.2 Regeneration Correctness

WalleBrain must support targeted regeneration semantics.

Fixture-driven pass condition:

- given a meeting draft and a `ReviewComment` anchored to the summary block
- and a `RevisionRequest` for block scope
- the regenerated result updates the targeted block
- while preserving:
  - original raw transcript
  - unrelated blocks unless the request is note-wide

This can initially be verified in a harness without a full production UI flow.

### P1.3 Export Completeness

The exported note must be useful as a long-term artifact without reopening the app.

Required sections:

- Summary
- Organized Transcript
- Key Points
- Decisions
- Action Items
- Open Loops
- Risks
- Related Projects
- Related People
- Participant Positions
- Live Transcript
- Final Transcript

### P1.4 Failure Behavior

Failure cases must degrade clearly, not silently.

Required behaviors:

- missing model configuration fails clearly
- invalid dictionary markdown fails clearly
- no-speech meetings do not hallucinate content
- post-process failure still preserves transcript and local artifacts
- failed regeneration does not destroy the previous accepted draft

### P1.5 Repeatability

Repeated acceptance runs must be safe.

Pass condition:

- running the acceptance suite repeatedly does not corrupt prior sessions or reports
- reports are timestamped or otherwise uniquely separated
- fixture outputs remain deterministic enough for regression comparison

---

## P2 Stretch Gates

These are explicitly valuable, but not required for this phase to pass.

### P2.1 Review UI Completeness

- inline review comments from every major note block
- issue-style review list
- apply / reject state transitions in UI

### P2.2 Person Continuity

- recurring participant extraction
- person-to-project linking
- person-level timeline updates

### P2.3 Pre-Meeting Briefing

- auto-generated project/person briefing before the next meeting

---

## Harness Engineering Requirements

These requirements exist specifically so the next implementation phase can be driven by automated harnesses.

### H1. Deterministic Fixture Inputs

The repo must contain or generate stable fixture inputs for:

- transcript-only evaluation
- session JSON compatibility evaluation
- review/regeneration evaluation
- project-link extraction evaluation

### H2. Golden Expectations

For each fixture, the repo must define expected outcomes in a machine-checkable form.

Allowed expectation styles:

- exact string match for small fields
- set containment for bullet outputs
- invariant assertions for uncertainty / no-hallucinated-actions
- project-link identity or unresolved-state assertions

### H3. Acceptance Runner

There must be one top-level acceptance command for this phase.

Target command:

- `swift run WalleBrainAcceptance`

The command may internally call specialized sub-harnesses, but this is the canonical gate.

### H4. Acceptance Report Shape

The report must be JSON and include at minimum:

- `build`
- `bundle`
- `realMeetingSmoke`
- `structuredDraft`
- `legacySessionDecode`
- `reviewRoundTrip`
- `fixtureEval`
- `export`
- `artifacts`

### H5. Fast Feedback Sub-Harnesses

In addition to the full acceptance runner, the repo should provide smaller harnesses for:

- fixture-only note evaluation
- review/regeneration behavior
- session compatibility checks

These do not replace the top-level gate, but they are required for efficient implementation iteration.

---

## Out Of Scope For This Phase

The following are not required for acceptance in this phase:

- full knowledge graph traversal
- generalized non-meeting data ingestion
- team collaboration workflows
- multi-user permission models
- perfect diarization
- perfect transcription accuracy benchmarking on arbitrary live audio
- auto-updating project and person pages from every accepted meeting

Those are future capabilities. This phase is about strong meeting notes plus the memory scaffolding required for compounding value.

---

## Pass / Fail Definition

### Pass

This phase passes only if:

- every P0 gate passes
- every P1 gate passes
- `swift run WalleBrainAcceptance` exits `0`
- a fresh report is written under `runtime/acceptance/native/`

### Fail

This phase fails if any of the following occur:

- the app cannot complete the real meeting flow
- the structured note fields are missing or not persisted
- legacy sessions break after model expansion
- review/revision artifacts are not durable
- project continuity signals are absent
- fixture-based quality invariants fail
- the acceptance runner cannot produce a machine-readable result

---

## One-Sentence Acceptance Bar

**WalleBrain is accepted for this phase when it can produce, preserve, review, and regression-test a structured meeting note that is ready to become cumulative project memory.**
