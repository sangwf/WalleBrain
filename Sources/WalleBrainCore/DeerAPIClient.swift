import Foundation

public actor DeerAPIClient {
  private let apiKey: String
  private let completionURL: URL
  private let modelChain: [String]

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    configuration: ModelConfiguration? = nil
  ) throws {
    let effectiveConfiguration = configuration ?? ModelConfigurationStore().load()
    let resolvedConfiguration = try ModelConfigurationResolver(environment: environment).resolve(effectiveConfiguration)

    guard let url = URL(string: resolvedConfiguration.baseURL) else {
      throw WalleBrainError.invalidResponse("Invalid Base URL: \(resolvedConfiguration.baseURL)")
    }

    self.apiKey = resolvedConfiguration.apiKey
    self.completionURL = Self.resolveCompletionURL(from: url)
    self.modelChain = resolvedConfiguration.models
  }

  public func summarize(transcript: String, dictionary: TermDictionary) async throws -> DeerAPIResult {
    var lastError: Error?

    for model in modelChain {
      do {
        return try await summarize(transcript: transcript, dictionary: dictionary, model: model)
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No DeerAPI model succeeded.")
  }

  public func summarizeFixtureTranscript(
    _ transcript: String,
    dictionary: TermDictionary
  ) async throws -> DeerAPIResult {
    var lastError: Error?

    for model in modelChain {
      do {
        return try await analyzeTranscript(
          transcript.trimmingCharacters(in: .whitespacesAndNewlines),
          model: model
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No DeerAPI model succeeded.")
  }

  public func testConnection() async throws -> DeerAPIResult {
    try await summarize(
      transcript: "这是一次连接测试。",
      dictionary: TermDictionary(title: "Connection Test", entries: [])
    )
  }

  public func reviseSummary(
    transcript: String,
    currentSummary: String,
    reviewComment: ReviewComment,
    request: RevisionRequest? = nil
  ) async throws -> SummaryRevisionResult {
    var lastError: Error?

    for model in modelChain {
      do {
        return try await reviseSummary(
          transcript: transcript,
          currentSummary: currentSummary,
          reviewComment: reviewComment,
          request: request,
          model: model
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No DeerAPI model succeeded.")
  }

  public func reviseListBlock(
    transcript: String,
    blockKind: MeetingBlockKind,
    currentItems: [String],
    reviewComment: ReviewComment,
    request: RevisionRequest? = nil
  ) async throws -> [String] {
    var lastError: Error?

    for model in modelChain {
      do {
        return try await reviseListBlock(
          transcript: transcript,
          blockKind: blockKind,
          currentItems: currentItems,
          reviewComment: reviewComment,
          request: request,
          model: model
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No DeerAPI model succeeded.")
  }

  public func reviseDecisionsBlock(
    transcript: String,
    currentDecisions: [MeetingDecision],
    reviewComment: ReviewComment,
    request: RevisionRequest? = nil
  ) async throws -> [MeetingDecision] {
    var lastError: Error?

    for model in modelChain {
      do {
        return try await reviseDecisionsBlock(
          transcript: transcript,
          currentDecisions: currentDecisions,
          reviewComment: reviewComment,
          request: request,
          model: model
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No DeerAPI model succeeded.")
  }

  private func summarize(
    transcript: String,
    dictionary: TermDictionary,
    model: String,
  ) async throws -> DeerAPIResult {
    let glossary = glossaryText(from: dictionary)

    // --- Pass 1: Transcript cleanup only ---
    let cleanupPrompt = """
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

    let cleanedTranscript = try await callCompletion(
      model: model,
      systemPrompt: "You are a transcript editor. Output cleaned text only, no JSON, no markdown fencing.",
      userPrompt: cleanupPrompt,
      maxTokens: 65536
    )

    return try await analyzeTranscript(
      cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
      model: model
    )
  }

  private func glossaryText(from dictionary: TermDictionary) -> String {
    dictionary.entries.map { entry in
      let aliases = entry.aliases.isEmpty ? "" : " aliases=\(entry.aliases.joined(separator: ", "))"
      let type = entry.type.map { " type=\($0)" } ?? ""
      let notes = entry.notes.map { " notes=\($0)" } ?? ""
      return "- \(entry.canonical)\(aliases)\(type)\(notes)"
    }.joined(separator: "\n")
  }

  private func analyzeTranscript(
    _ transcript: String,
    model: String
  ) async throws -> DeerAPIResult {
    // --- Pass 2: Analysis (summary + structured meeting memory) ---
    let analysisPrompt = """
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

    let analysisContent = try await callCompletion(
      model: model,
      systemPrompt: "You output strict JSON only.",
      userPrompt: analysisPrompt,
      maxTokens: 4096
    )

    let jsonText = try Self.extractJSON(from: analysisContent)
    let decoded = try JSONDecoder().decode(AnalysisEnvelope.self, from: Data(jsonText.utf8))

    let filteredDecisions = filterDecisions(decoded.decisions, sourceTranscript: transcript)

    return DeerAPIResult(
      provider: "deerapi",
      model: model,
      summary: decoded.summary,
      organizedTranscript: transcript,
      keyPoints: decoded.keyPoints,
      actionItems: decoded.actionItems,
      decisions: filteredDecisions.map {
        MeetingDecision(
          text: $0.text,
          status: $0.status,
          confidence: $0.confidence,
          relatedProjectID: $0.relatedProjectID?.nilIfBlank,
          evidence: $0.evidence?.nilIfBlank
        )
      },
      openLoops: decoded.openLoops.map {
        MeetingOpenLoop(
          type: $0.type,
          text: $0.text,
          owner: $0.owner?.nilIfBlank,
          dueHint: $0.dueHint?.nilIfBlank,
          status: $0.status,
          relatedProjectID: $0.relatedProjectID?.nilIfBlank,
          evidence: $0.evidence?.nilIfBlank
        )
      },
      risks: decoded.risks.map {
        MeetingRisk(
          text: $0.text,
          confidence: $0.confidence,
          relatedProjectID: $0.relatedProjectID?.nilIfBlank,
          evidence: $0.evidence?.nilIfBlank
        )
      },
      participantPositions: decoded.participantPositions.map {
        ParticipantPosition(
          person: $0.person.map {
            PersonReference(
              id: $0.id,
              displayName: $0.displayName,
              aliases: $0.aliases
            )
          },
          label: $0.label,
          stance: $0.stance,
          confidence: $0.confidence,
          evidence: $0.evidence?.nilIfBlank
        )
      },
      projectLinks: decoded.projectLinks.map {
        MeetingProjectLink(
          project: ProjectReference(
            id: $0.project.id,
            title: $0.project.title,
            aliases: $0.project.aliases
          ),
          role: $0.role,
          status: $0.status,
          confidence: $0.confidence,
          evidence: $0.evidence?.nilIfBlank
        )
      },
      relatedPeople: decoded.relatedPeople.map {
        PersonReference(
          id: $0.id,
          displayName: $0.displayName,
          aliases: $0.aliases
        )
      }
    )
  }

  private func reviseSummary(
    transcript: String,
    currentSummary: String,
    reviewComment: ReviewComment,
    request: RevisionRequest?,
    model: String
  ) async throws -> SummaryRevisionResult {
    let requestInstructions = request?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let proposedText = reviewComment.proposedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let currentSummary = currentSummary.trimmingCharacters(in: .whitespacesAndNewlines)

    let prompt = """
    You revise only the summary block of a Chinese meeting note.

    Source transcript:
    \(transcript)

    Current summary:
    \(currentSummary)

    Review feedback:
    - type: \(reviewComment.type.rawValue)
    - comment: \(reviewComment.comment)
    - proposedText: \(proposedText.isEmpty ? "none" : proposedText)
    - requestInstructions: \(requestInstructions.isEmpty ? "none" : requestInstructions)

    Requirements:
    - Output simplified Chinese only.
    - Output the revised summary only, with no markdown, no bullets, and no labels.
    - Keep it to at most two short paragraphs.
    - Revise only the summary block. Do not add unrelated material.
    - Preserve uncertainty exactly. If the transcript is tentative, the revised summary must remain tentative.
    - Do not invent facts, ownership, family relationships, or decisions not supported by the transcript.
    - If the feedback says something is missing, add it only if it is supported by the transcript.
    - If the feedback says something is overstated, make it more cautious.
    - If `proposedText` is usable and supported by the transcript, prefer incorporating it.
    """

    let revisedSummary = try await callCompletion(
      model: model,
      systemPrompt: "You revise a summary block only. Output plain text only.",
      userPrompt: prompt,
      maxTokens: 1024
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    guard !revisedSummary.isEmpty else {
      throw WalleBrainError.invalidResponse("Summary revision returned empty text.")
    }

    return SummaryRevisionResult(
      provider: "deerapi",
      model: model,
      summary: revisedSummary
    )
  }

  private func reviseListBlock(
    transcript: String,
    blockKind: MeetingBlockKind,
    currentItems: [String],
    reviewComment: ReviewComment,
    request: RevisionRequest?,
    model: String
  ) async throws -> [String] {
    let requestInstructions = request?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let proposedText = reviewComment.proposedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let currentItemsText = currentItems.isEmpty
      ? "[]"
      : currentItems.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

    let blockLabel: String
    let blockRequirements: String
    switch blockKind {
    case .keyPoint:
      blockLabel = "key points"
      blockRequirements = """
      - Keep concrete, specific points only.
      - Preserve tentative language exactly as stated in the transcript.
      - Output only the final bullet texts without numbering.
      """
    case .actionItem:
      blockLabel = "action items"
      blockRequirements = """
      - Keep only explicit commitments, requests, or agreed follow-ups.
      - Do NOT convert background discussion or speculation into action items.
      - Output only the final bullet texts without numbering.
      """
    default:
      throw WalleBrainError.invalidResponse("Unsupported list block for revision: \(blockKind.rawValue)")
    }

    let prompt = """
    You revise only the \(blockLabel) block of a Chinese meeting note.

    Source transcript:
    \(transcript)

    Current \(blockLabel):
    \(currentItemsText)

    Review feedback:
    - type: \(reviewComment.type.rawValue)
    - comment: \(reviewComment.comment)
    - proposedText: \(proposedText.isEmpty ? "none" : proposedText)
    - requestInstructions: \(requestInstructions.isEmpty ? "none" : requestInstructions)

    Return strict JSON:
    {
      "items": ["string"]
    }

    Requirements:
    - Use simplified Chinese.
    - Revise only this block.
    \(blockRequirements)
    - Use `proposedText` only if it is supported by the transcript.
    - If no items remain after applying the feedback, return an empty array.
    """

    let content = try await callCompletion(
      model: model,
      systemPrompt: "You revise one meeting-note list block only. Output strict JSON only.",
      userPrompt: prompt,
      maxTokens: 1024
    )

    let jsonText = try Self.extractJSON(from: content)
    let decoded = try JSONDecoder().decode(RevisionListEnvelope.self, from: Data(jsonText.utf8))
    return decoded.items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }

  private func reviseDecisionsBlock(
    transcript: String,
    currentDecisions: [MeetingDecision],
    reviewComment: ReviewComment,
    request: RevisionRequest?,
    model: String
  ) async throws -> [MeetingDecision] {
    let requestInstructions = request?.instructions.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let proposedText = reviewComment.proposedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let currentDecisionsText = currentDecisions.isEmpty
      ? "[]"
      : currentDecisions.enumerated().map { index, item in
        "\(index + 1). \(item.text) [\(item.status.rawValue)]"
      }.joined(separator: "\n")

    let prompt = """
    You revise only the decisions block of a Chinese meeting note.

    Source transcript:
    \(transcript)

    Current decisions:
    \(currentDecisionsText)

    Review feedback:
    - type: \(reviewComment.type.rawValue)
    - comment: \(reviewComment.comment)
    - proposedText: \(proposedText.isEmpty ? "none" : proposedText)
    - requestInstructions: \(requestInstructions.isEmpty ? "none" : requestInstructions)

    Return strict JSON:
    {
      "items": [
        {
          "text": "string",
          "status": "candidate|confirmed"
        }
      ]
    }

    Requirements:
    - Use simplified Chinese.
    - Revise only the decisions block.
    - Include only actual decisions, confirmations, or strong agreed outcomes supported by the transcript.
    - Do NOT create decisions from tentative planning language alone.
    - Preserve uncertainty. If a decision is not fully confirmed, use `candidate`.
    - Use `proposedText` only if it is supported by the transcript.
    - If no valid decisions remain after applying the feedback, return an empty array.
    """

    let content = try await callCompletion(
      model: model,
      systemPrompt: "You revise one meeting-note decisions block only. Output strict JSON only.",
      userPrompt: prompt,
      maxTokens: 1200
    )

    let jsonText = try Self.extractJSON(from: content)
    let decoded = try JSONDecoder().decode(DecisionRevisionEnvelope.self, from: Data(jsonText.utf8))
    let filtered = filterDecisions(decoded.items, sourceTranscript: transcript)

    return filtered.map { envelope in
      if let existing = currentDecisions.first(where: { $0.text == envelope.text }) {
        return MeetingDecision(
          id: existing.id,
          text: existing.text,
          status: envelope.status,
          confidence: existing.confidence,
          relatedProjectID: existing.relatedProjectID,
          evidence: existing.evidence
        )
      }

      return MeetingDecision(
        text: envelope.text,
        status: envelope.status
      )
    }
  }

  private func callCompletion(
    model: String,
    systemPrompt: String,
    userPrompt: String,
    maxTokens: Int,
  ) async throws -> String {
    var request = URLRequest(url: completionURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": userPrompt],
      ],
      "temperature": 0.2,
      "max_tokens": maxTokens,
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (statusCode, data) = try Self.performDirectRequest(request)

    guard (200..<300).contains(statusCode) else {
      throw WalleBrainError.invalidResponse(
        "HTTP \(statusCode): \(String(decoding: data, as: UTF8.self))"
      )
    }

    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard
      let choices = payload?["choices"] as? [[String: Any]],
      let firstChoice = choices.first,
      let message = firstChoice["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      throw WalleBrainError.invalidResponse("Missing choices/message/content.")
    }

    return content
  }

  private static func extractJSON(from content: String) throws -> String {
    if let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") {
      return String(content[start...end])
    }

    throw WalleBrainError.invalidModelPayload
  }

  private static func resolveCompletionURL(from url: URL) -> URL {
    let path = url.path.lowercased()
    if path.hasSuffix("/chat/completions") {
      return url
    }

    return url.appending(path: "chat/completions")
  }

  private static func performDirectRequest(_ request: URLRequest) throws -> (Int, Data) {
    guard let url = request.url else {
      throw WalleBrainError.invalidResponse("Missing request URL.")
    }

    let bodyData = request.httpBody ?? Data()
    let marker = "__WALLEBRAIN_HTTP_STATUS__:"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
      "--noproxy", "*",
      "-sS",
      "--max-time", "1800",
      "-X", request.httpMethod ?? "POST",
      "-H", "Authorization: \(request.value(forHTTPHeaderField: "Authorization") ?? "")",
      "-H", "Content-Type: \(request.value(forHTTPHeaderField: "Content-Type") ?? "application/json")",
      "-w", "\n\(marker)%{http_code}",
      url.absoluteString,
      "--data-binary", "@-",
    ]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdinPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = stdinPipe

    try process.run()
    if !bodyData.isEmpty {
      stdinPipe.fileHandleForWriting.write(bodyData)
    }
    try? stdinPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    guard process.terminationStatus == 0 else {
      let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw WalleBrainError.invalidResponse(stderrText.isEmpty ? "curl request failed." : stderrText)
    }

    let stdoutText = String(decoding: stdoutData, as: UTF8.self)
    guard let markerRange = stdoutText.range(of: marker, options: .backwards) else {
      throw WalleBrainError.invalidResponse("Missing HTTP status marker from curl output.")
    }

    let bodyText = String(stdoutText[..<markerRange.lowerBound]).trimmingCharacters(in: .newlines)
    let statusText = stdoutText[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let statusCode = Int(statusText) else {
      throw WalleBrainError.invalidResponse("Invalid HTTP status marker from curl output: \(statusText)")
    }

    return (statusCode, Data(bodyText.utf8))
  }

  private func filterDecisions(
    _ decisions: [DecisionEnvelope],
    sourceTranscript: String
  ) -> [DecisionEnvelope] {
    guard !decisions.isEmpty else {
      return decisions
    }

    let normalized = sourceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      return []
    }

    let explicitDecisionSignals = [
      "决定",
      "确认",
      "定了",
      "就这么做",
      "按这个方案推进",
      "下周上线",
      "先不并",
      "先别并",
      "不并到",
      "暂不并",
      "暂不推进",
      "保持独立",
    ]

    let tentativeOnlySignals = [
      "可能",
      "再看",
      "先观察",
      "先同步背景",
      "暂缓讨论",
      "之后再说",
      "没有形成明确 follow-up",
      "没有明确 follow-up",
      "后面再议",
    ]

    let hasExplicitDecisionSignal = explicitDecisionSignals.contains { normalized.contains($0) }
    let hasTentativeOnlySignal = tentativeOnlySignals.contains { normalized.contains($0) }

    if !hasExplicitDecisionSignal && hasTentativeOnlySignal {
      return []
    }

    return decisions
  }
}

private struct AnalysisEnvelope: Decodable {
  let summary: String
  let keyPoints: [String]
  let actionItems: [String]
  let decisions: [DecisionEnvelope]
  let openLoops: [OpenLoopEnvelope]
  let risks: [RiskEnvelope]
  let participantPositions: [ParticipantPositionEnvelope]
  let projectLinks: [ProjectLinkEnvelope]
  let relatedPeople: [PersonEnvelope]

  private enum CodingKeys: String, CodingKey {
    case summary
    case keyPoints
    case actionItems
    case decisions
    case openLoops
    case risks
    case participantPositions
    case projectLinks
    case relatedPeople
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(String.self, forKey: .summary)
    keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
    actionItems = try container.decodeIfPresent([String].self, forKey: .actionItems) ?? []
    decisions = try container.decodeIfPresent([DecisionEnvelope].self, forKey: .decisions) ?? []
    openLoops = try container.decodeIfPresent([OpenLoopEnvelope].self, forKey: .openLoops) ?? []
    risks = try container.decodeIfPresent([RiskEnvelope].self, forKey: .risks) ?? []
    participantPositions = try container.decodeIfPresent([ParticipantPositionEnvelope].self, forKey: .participantPositions) ?? []
    projectLinks = try container.decodeIfPresent([ProjectLinkEnvelope].self, forKey: .projectLinks) ?? []
    relatedPeople = try container.decodeIfPresent([PersonEnvelope].self, forKey: .relatedPeople) ?? []
  }
}

private struct RevisionListEnvelope: Decodable {
  let items: [String]
}

private struct DecisionRevisionEnvelope: Decodable {
  let items: [DecisionEnvelope]
}

private struct DecisionEnvelope: Decodable {
  let text: String
  let status: DecisionStatus
  let confidence: Double
  let relatedProjectID: String?
  let evidence: String?

  private enum CodingKeys: String, CodingKey {
    case text
    case status
    case confidence
    case relatedProjectID
    case evidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    status = try container.decodeIfPresent(DecisionStatus.self, forKey: .status) ?? .candidate
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    relatedProjectID = try container.decodeIfPresent(String.self, forKey: .relatedProjectID)
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
  }
}

private struct OpenLoopEnvelope: Decodable {
  let type: OpenLoopType
  let text: String
  let owner: String?
  let dueHint: String?
  let status: OpenLoopStatus
  let relatedProjectID: String?
  let evidence: String?

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case owner
    case dueHint
    case status
    case relatedProjectID
    case evidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    type = try container.decodeIfPresent(OpenLoopType.self, forKey: .type) ?? .followUp
    text = try container.decode(String.self, forKey: .text)
    owner = try container.decodeIfPresent(String.self, forKey: .owner)
    dueHint = try container.decodeIfPresent(String.self, forKey: .dueHint)
    status = try container.decodeIfPresent(OpenLoopStatus.self, forKey: .status) ?? .open
    relatedProjectID = try container.decodeIfPresent(String.self, forKey: .relatedProjectID)
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
  }
}

private struct RiskEnvelope: Decodable {
  let text: String
  let confidence: Double
  let relatedProjectID: String?
  let evidence: String?

  private enum CodingKeys: String, CodingKey {
    case text
    case confidence
    case relatedProjectID
    case evidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(String.self, forKey: .text)
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    relatedProjectID = try container.decodeIfPresent(String.self, forKey: .relatedProjectID)
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
  }
}

private struct ParticipantPositionEnvelope: Decodable {
  let person: PersonEnvelope?
  let label: String
  let stance: String
  let confidence: Double
  let evidence: String?

  private enum CodingKeys: String, CodingKey {
    case person
    case label
    case stance
    case confidence
    case evidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    person = try container.decodeIfPresent(PersonEnvelope.self, forKey: .person)
    label = try container.decodeIfPresent(String.self, forKey: .label) ?? person?.displayName ?? "参与者"
    stance = try container.decode(String.self, forKey: .stance)
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
  }
}

private struct ProjectLinkEnvelope: Decodable {
  let project: ProjectEnvelope
  let role: ProjectLinkRole
  let status: ProjectLinkStatus
  let confidence: Double
  let evidence: String?

  private enum CodingKeys: String, CodingKey {
    case project
    case role
    case status
    case confidence
    case evidence
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    project = try container.decode(ProjectEnvelope.self, forKey: .project)
    role = try container.decodeIfPresent(ProjectLinkRole.self, forKey: .role) ?? .mentioned
    status = try container.decodeIfPresent(ProjectLinkStatus.self, forKey: .status) ?? .unresolved
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    evidence = try container.decodeIfPresent(String.self, forKey: .evidence)
  }
}

private struct ProjectEnvelope: Decodable {
  let id: String
  let title: String
  let aliases: [String]

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case aliases
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? title
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .joined(separator: "-")
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}

private struct PersonEnvelope: Decodable {
  let id: String
  let displayName: String
  let aliases: [String]

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case aliases
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    displayName = try container.decode(String.self, forKey: .displayName)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? displayName
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .joined(separator: "-")
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
  }
}

private extension String {
  var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}

private extension KeyedDecodingContainer {
  func decodeLossyDouble(forKey key: Key) throws -> Double? {
    if let value = try decodeIfPresent(Double.self, forKey: key) {
      return value
    }

    if let value = try decodeIfPresent(Int.self, forKey: key) {
      return Double(value)
    }

    if let value = try decodeIfPresent(String.self, forKey: key) {
      return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return nil
  }
}
