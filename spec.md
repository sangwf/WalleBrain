# WalleBrain Product Spec v0.3

## 1. Product Thesis

WalleBrain is a **meeting-first second brain**.

It is not primarily:

- a generic meeting SaaS
- a pure transcription tool
- a broad personal knowledge base for everything

It is primarily:

- a system that captures meeting discussions
- turns them into high-quality structured notes
- lets the user review and critique those notes interactively
- accumulates cross-meeting context around projects, people, decisions, and open loops

The core idea is:

**every meeting is not just a note, but a memory update event.**

---

## 2. North Star

Before a new meeting starts, WalleBrain should already know:

- what this project was last about
- what this person previously cared about
- what decisions have already been made
- what open questions are still unresolved
- what follow-ups are pending

After a meeting ends, WalleBrain should:

- produce a reliable first draft
- let the user improve it through structured review
- preserve raw evidence and revised outputs separately
- update long-lived project and person context

---

## 3. Primary User

Phase 1 targets a single primary user:

- the user themselves
- on macOS
- attending recurring discussions about products, projects, clients, or strategy
- valuing long-term context over one-off transcript export

Typical meetings:

- product discussions
- internal syncs
- customer conversations
- partnership / business development meetings
- hiring or evaluation conversations
- brainstorming sessions

---

## 4. Core Product Goal

The first and most important goal is:

**make post-meeting notes materially better.**

"Better" means:

- fewer factual mistakes
- fewer missed key points
- clearer distinction between facts, decisions, risks, and follow-ups
- less hallucinated action extraction
- better preservation of uncertainty, attribution, and nuance
- better continuity from one meeting to the next

This goal takes priority over:

- broad integrations
- full knowledge graph ambitions
- large-scale retrieval infrastructure
- generalized personal knowledge capture

---

## 5. Product Principles

1. **Meeting-first**
   Meetings are the main input. Everything else is secondary.

2. **Quality before breadth**
   A stronger review and post-process loop matters more than more integrations.

3. **Raw evidence is preserved**
   Raw transcript, corrected transcript, organized transcript, and final note are distinct layers.

4. **Interactive refinement beats one-shot generation**
   The user must be able to critique and regenerate notes after the first draft.

5. **Cross-meeting continuity matters**
   Notes should accumulate into project and person context.

6. **Local-first artifacts**
   Audio, transcripts, and markdown outputs should remain inspectable and editable by the user.

7. **Second brain, not black box**
   The user should be able to see what was captured, what was inferred, and what was revised.

---

## 6. Problem Statement

Existing meeting tools usually fail in one of two ways:

1. They generate shallow summaries that are hard to trust.
2. They produce isolated notes that do not compound into long-term memory.

For this user, the real problem is:

- meetings are frequent
- discussions recur around the same projects and people
- the most valuable knowledge is spread across many conversations
- important context gets lost between meetings
- current post-processing is helpful but still too weak and too static

The missing piece is not only better transcription.

The missing piece is:

**a reviewable, accumulative post-meeting intelligence loop.**

---

## 7. Product Definition

WalleBrain is a native macOS workflow that:

1. captures meeting audio and transcript artifacts
2. produces a structured first draft after the meeting
3. supports interactive review, critique, and regeneration
4. links the meeting to projects and people
5. updates long-lived memory objects from the confirmed meeting output

---

## 8. Core Objects

WalleBrain revolves around five product objects.

### 8.1 Meeting

A `Meeting` is the source event.

It contains:

- title
- timestamps
- participants if known
- audio artifact
- raw transcript
- corrected transcript
- organized transcript
- structured note fields
- review comments
- resolved final note

### 8.2 Project

A `Project` is a cross-meeting continuity container.

It accumulates:

- current state
- recent decisions
- open questions
- risks and blockers
- outstanding follow-ups
- related meetings

### 8.3 Person

A `Person` is a recurring human context object.

It accumulates:

- identity and aliases
- relationship context
- participation in meetings
- repeated concerns, positions, or themes
- related projects

### 8.4 Decision

A `Decision` is a confirmed outcome worth long-term recall.

It should preserve:

- decision text
- meeting source
- confidence / confirmation status
- related project
- evidence reference

### 8.5 Open Loop

An `Open Loop` is unresolved work or uncertainty.

Examples:

- action items
- pending follow-ups
- unresolved questions
- known risks awaiting action

---

## 9. Information Layers

Each meeting should preserve multiple layers instead of flattening everything into one note.

### Layer 1: Raw Capture

- audio
- raw live transcript
- low-level transcript chunks / timing

### Layer 2: Corrected Capture

- glossary-informed corrections
- user-applied term fixes
- transcript cleanup while preserving meaning

### Layer 3: Structured Understanding

- executive summary
- organized transcript
- key points
- decisions
- action items
- risks
- open questions
- participant positions
- project signals

### Layer 4: Reviewed Finalization

- user comments on generated blocks
- regenerated blocks
- accepted final note
- updates written back to projects and people

This layered model is mandatory. It is how WalleBrain avoids becoming a black-box summarizer.

---

## 10. Primary Workflow

### 10.1 During Meeting

The system:

- starts and maintains a meeting session
- captures audio
- records live transcript state
- preserves enough structure for later correction

Realtime visibility matters, but realtime output is not the final artifact.

### 10.2 First Draft After Meeting

After stop, WalleBrain generates an initial structured note.

The first draft should include at minimum:

- executive summary
- organized transcript
- key points
- action items
- initial project candidates

### 10.3 Interactive Review

This is the most important new capability.

The user must be able to comment on generated content, not only fix words.

Supported feedback types should include:

- factual error
- omission
- wrong emphasis
- wrong attribution
- style correction
- invalid action item
- should be a decision instead
- should be linked to a project
- should be linked to a person

### 10.4 Regeneration

The system should regenerate selectively where possible.

Preferred regeneration scopes:

- one summary block
- one organized transcript block
- one action item set
- one project extraction block
- full note only when necessary

### 10.5 Memory Update

Once the user accepts the note, WalleBrain updates longer-lived objects:

- project timeline
- project current state
- person context
- decisions
- open loops

---

## 11. Note Quality Requirements

The structured note must distinguish clearly between different kinds of content.

At minimum, WalleBrain should separate:

- factual claims
- tentative statements
- decisions
- action items
- open questions
- risks or blockers
- background discussion

The system must avoid these failure modes:

- turning casual discussion into action items
- turning uncertainty into certainty
- inventing participant roles or ownership
- overcompressing the discussion into generic bullets
- dropping important examples, numbers, timelines, or caveats

---

## 12. Interactive Review Requirements

The post-meeting experience must feel like reviewing a draft with a smart editor, not just editing text manually.

The system should support:

1. **Comment on a block**
   The user can anchor feedback to a paragraph, bullet, transcript selection, or generated field.

2. **Suggest or provide replacement text**
   The user can either comment or provide exact preferred wording.

3. **Reclassify content**
   The user can convert:
   - key point -> decision
   - key point -> background
   - action item -> open question
   - transcript fragment -> project update

4. **Link to project or person**
   The user can explicitly associate a piece of content with a project or person.

5. **Regenerate from review feedback**
   The system should incorporate user commentary and produce an improved version.

6. **Learn from accepted feedback**
   Repeated user corrections should improve future note generation behavior.

---

## 13. Project Continuity Requirements

Meetings are often related across time through projects.

WalleBrain must treat project continuity as a first-class concern.

Minimum expectations:

- a meeting can map to one or more projects
- one project can have many meetings
- the system extracts candidate project references from each meeting
- ambiguous project references remain unresolved until confirmed
- confirmed project links update that project's timeline and current state

The user experience should make it easy to answer:

- what changed on this project since last time
- what is still unresolved
- what was newly decided
- what follow-up remains

---

## 14. Person Continuity Requirements

Repeated participants should accumulate context over time.

WalleBrain should help answer:

- who this person is
- what projects they are involved in
- what themes they repeatedly care about
- what unresolved threads exist with them

This does not require a full CRM in early phases.
It does require recurring meeting knowledge to stop resetting to zero.

---

## 15. Minimal Data Model Direction

The product should evolve toward these logical entities:

- `Meeting`
- `MeetingBlock`
- `ReviewComment`
- `RevisionRequest`
- `Project`
- `MeetingProjectLink`
- `Person`
- `Decision`
- `OpenLoop`

Suggested direction:

- `Meeting` remains the event record
- `MeetingBlock` represents individually reviewable generated sections
- `ReviewComment` captures anchored user feedback
- `RevisionRequest` drives selective regeneration
- `MeetingProjectLink` records confidence and evidence for project association

This is a product-level target model, not a rigid implementation prescription.

---

## 16. What WalleBrain Is Not Doing Yet

The following are explicitly not the near-term goal:

- becoming a full everything-ingest personal brain
- building a broad knowledge graph before note quality is strong
- solving every kind of document management
- optimizing for multi-user collaboration first
- prioritizing retrieval infrastructure over note intelligence

The order matters:

1. stronger notes
2. stronger review loop
3. stronger cross-meeting continuity
4. broader second-brain capabilities

---

## 17. Roadmap

### Phase A: Better Single-Meeting Notes

Goals:

- improve transcript cleanup fidelity
- strengthen structured note schema
- separate decisions / actions / risks / open questions
- reduce hallucinated or low-value action extraction

Success condition:

- the first draft is useful often enough that the user wants to review it rather than rewrite from scratch

### Phase B: Interactive Review And Regeneration

Goals:

- comment on generated blocks
- partial regeneration
- stronger correction memory
- persistent note-style preference learning

Success condition:

- user feedback reliably improves the note in one or two review cycles

### Phase C: Project-First Continuity

Goals:

- extract project candidates
- confirm project associations
- update project timelines and current state
- generate project-aware meeting context

Success condition:

- repeated meetings about the same project visibly compound into usable context

### Phase D: Person And Relationship Continuity

Goals:

- recurring participant context
- person-level summaries and open threads
- person-to-project linkage

Success condition:

- prep for a recurring meeting feels materially better because prior context is already available

### Phase E: Full Meeting-First Second Brain

Goals:

- accepted meeting outputs update durable project, person, decision, and open-loop memory
- pre-meeting briefing becomes automatic
- the user experiences WalleBrain as cumulative memory, not a note exporter

---

## 18. Product Success Metrics

WalleBrain is succeeding when:

- the user trusts the post-meeting draft enough to review, not discard
- review feedback is cheaper than rewriting manually
- action items are more precise and less noisy
- project continuity becomes visible across meetings
- the user increasingly relies on WalleBrain for recall before future discussions

Qualitative signals matter more than vanity metrics in early phases.

Good early indicators:

- "this actually captured what mattered"
- "this caught the unresolved thread"
- "this remembered what we said last time"
- "I only needed to correct a few blocks, not rewrite everything"

---

## 19. One-Sentence Product Definition

**WalleBrain is a meeting-first second brain that turns recurring discussions into reviewable notes and cumulative project memory.**
