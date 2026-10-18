import Foundation

/// Prompts shared by every post-processing backend (OpenAI-compatible API and Codex CLI),
/// so both produce the same organized transcript and the same analysis JSON shape.
enum MeetingPostProcessingPrompts {
  static let organizeSystemPrompt = "You are a transcript editor. Output cleaned text only, no JSON, no markdown fencing."
  static let analysisSystemPrompt = "You output strict JSON only."

  static func glossaryText(from dictionary: TermDictionary) -> String {
    dictionary.entries.map { entry in
      let aliases = entry.aliases.isEmpty ? "" : " aliases=\(entry.aliases.joined(separator: ", "))"
      let type = entry.type.map { " type=\($0)" } ?? ""
      let notes = entry.notes.map { " notes=\($0)" } ?? ""
      return "- \(entry.canonical)\(aliases)\(type)\(notes)"
    }.joined(separator: "\n")
  }

  static func organizeUserPrompt(transcript: String, glossary: String) -> String {
    """
    You are a Chinese transcript editor producing a readable meeting record.

    Glossary (for correcting misrecognized terms):
    \(glossary)

    Raw transcript:
    \(transcript)

    TASK: Produce an organized transcript that is easy to read but preserves all substantive content.
    This is NOT a summary. It must remain a detailed, speaker-by-speaker meeting record.

    What to REMOVE:
    - ASR stutter and word-level repetition
    - Filler sounds and meaningless back-channel (standalone 嗯/啊/喂/OK, "对对对" when it's just agreement noise)
    - Verbal crutches that add no meaning ("说白了", "的话呢", "怎么说呢", "就是说", "对不对")
    - Signal drops, broken fragments, phone reconnection noise

    What to KEEP (this is critical — do not lose ANY of these):
    - Every factual claim, number, percentage, price, timeline
    - Every example and anecdote (e.g. 有赞的案例, FA的坑, 体量匹配问题)
    - Every opinion, judgment, and recommendation
    - Every question asked and answer given
    - Emotional expressions that reflect the speaker's stance ("我靠这个好操作", "心理包袱大")
    - Names of companies, people, and concepts
    - Family relationships, ownership, and attribution exactly as stated in the transcript
    - Topic proportions: if one topic takes most of the conversation, keep that weight in the organized transcript
    - Uncertainty and hedging words such as “可能”, “大概”, “先看看”, “留意一下”, “也许”, “不一定”

    Style:
    - Label speakers A:/B: with each turn as a separate paragraph.
    - Lightly smooth incomplete sentences into complete ones, but keep the speaker's vocabulary and sequence of ideas.
    - Do NOT rewrite in formal/written style — it should still read like a conversation, just a clean one.
    - Do NOT aggressively compress. Keep most informational detail from the raw transcript.
    - Fix ASR misrecognitions using context and the glossary.
    - Do NOT infer or rewrite family relationships unless the transcript explicitly states them.
    - If attribution is ambiguous, preserve the ambiguity instead of guessing.
    - Preserve the speaker's confidence level. If something was tentative or speculative in the raw transcript, it must remain tentative or speculative.
    - Use simplified Chinese.
    - Output plain text only, no JSON, no markdown.
    """
  }

  static func analysisUserPrompt(transcript: String) -> String {
    """
    You are preparing a Chinese meeting note from the following transcript.

    Transcript:
    \(transcript)

    Return strict JSON with this shape:
    {
      "summary": "string",
      "keyPoints": ["string"],
      "actionItems": ["string"],
      "decisions": [
        {
          "text": "string",
          "status": "candidate|confirmed",
          "confidence": 0.0,
          "relatedProjectID": "string|null",
          "evidence": "string|null"
        }
      ],
      "openLoops": [
        {
          "type": "actionItem|openQuestion|followUp|risk",
          "text": "string",
          "owner": "string|null",
          "dueHint": "string|null",
          "status": "open|closed|dropped",
          "relatedProjectID": "string|null",
          "evidence": "string|null"
        }
      ],
      "risks": [
        {
          "text": "string",
          "confidence": 0.0,
          "relatedProjectID": "string|null",
          "evidence": "string|null"
        }
      ],
      "participantPositions": [
        {
          "person": {
            "id": "string",
            "displayName": "string",
            "aliases": ["string"]
          },
          "label": "string",
          "stance": "string",
          "confidence": 0.0,
          "evidence": "string|null"
        }
      ],
      "projectLinks": [
        {
          "project": {
            "id": "string",
            "title": "string",
            "aliases": ["string"]
          },
          "role": "primary|secondary|mentioned",
          "status": "unresolved|confirmed|rejected",
          "confidence": 0.0,
          "evidence": "string|null"
        }
      ],
      "relatedPeople": [
        {
          "id": "string",
          "displayName": "string",
          "aliases": ["string"]
        }
      ]
    }

    Requirements:
    - Use simplified Chinese.
    - summary: Two short paragraphs max, weighted by what actually dominated the conversation. Do not flatten all topics into equal importance.
    - keyPoints: Concrete, specific points with numbers and details where available. Keep tentative items marked as tentative if the transcript was tentative.
    - actionItems: Include only explicit commitments, requests, or agreed follow-ups. Do NOT turn casual ideas, background discussion, or speculative suggestions into action items.
    - decisions: Only include actual decisions, confirmations, or strong agreed outcomes. If uncertain, use `candidate`, not `confirmed`.
    - If the transcript contains explicit commitment or confirmation language such as “决定”, “确认”, “定了”, “就这么做”, “下周上线”, or “按这个方案推进”, you MUST extract a decision unless the sentence is clearly hypothetical.
    - Decision text must preserve the concrete outcome with timing and object. Example: “我们决定 Atlas 下周上线，这周内把发布 checklist 补齐。” should yield a decision containing “Atlas 下周上线”.
    - Do NOT create a decision from tentative planning language alone. Phrases like “可能”, “再看”, “先观察”, “先同步背景”, “暂缓讨论”, “之后再说”, or “没有形成明确 follow-up” are not decisions unless the transcript also contains an explicit confirmation or commitment.
    - Example: for “预算可能下个月再看，先观察一下。”, `decisions` MUST be `[]`, while the follow-up can stay in `openLoops`.
    - “先不并到现有项目”, “暂不推进”, or similar language can count as a decision only when the speaker is clearly setting a current course of action rather than merely speculating.
    - openLoops: Include unresolved questions, follow-ups, explicit action items, and unresolved risks.
    - risks: Include only explicit blockers, risks, or concerns.
    - participantPositions: Only include if a participant's stance is actually expressed in the transcript.
    - projectLinks: Extract projects, workstreams, or recurring initiatives mentioned in the transcript.
    - Use kebab-case IDs for `project.id` and `person.id`.
    - For project IDs, remove generic prefixes if needed, but keep them stable and readable. Example: `atlas-launch`.
    - If a mentioned project cannot be confidently mapped to an established project identity, still include it with `status = "unresolved"`.
    - If the transcript says a thing should NOT yet be merged into an existing project, or the identity is still ambiguous, the related `projectLinks` item must remain `unresolved`, not `confirmed`.
    - Do not invent facts not in the transcript.
    - Do not invent or normalize family relationships, ownership, or roles. If the transcript is ambiguous, keep the wording ambiguous.
    - When referring to participants, prefer A/B or neutral phrasing over making unsupported assumptions.
    - Do not convert tentative language into definitive statements. Preserve “可能/打算/看看/留意一下/有机会” as tentative.
    - If there are no items for a field, return an empty array.
    """
  }
}
