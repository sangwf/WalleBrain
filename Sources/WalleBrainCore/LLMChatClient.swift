import Foundation

public actor LLMChatClient {
  private let apiKey: String
  private let completionURL: URL
  private let modelChain: [String]
  private let providerLabel: String
  private let networkPolicy: NetworkTransportPolicy

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    configuration: ModelConfiguration? = nil,
    networkPolicy: NetworkTransportPolicy = .llmDefault()
  ) throws {
    let effectiveConfiguration = configuration ?? ModelConfigurationStore().load()
    let resolvedConfiguration = try ModelConfigurationResolver(environment: environment).resolve(effectiveConfiguration)

    guard let url = URL(string: resolvedConfiguration.baseURL) else {
      throw WalleBrainError.invalidResponse("Invalid Base URL: \(resolvedConfiguration.baseURL)")
    }

    self.apiKey = resolvedConfiguration.apiKey
    self.completionURL = Self.resolveCompletionURL(from: url)
    self.modelChain = resolvedConfiguration.models
    self.providerLabel = resolvedConfiguration.providerLabel
    self.networkPolicy = networkPolicy
  }

  public var configuredModels: [String] {
    modelChain
  }

  public func summarize(transcript: String, dictionary: TermDictionary) async throws -> LLMPostProcessingResult {
    let organized = try await organizeTranscript(transcript: transcript, dictionary: dictionary)
    return try await analyzeOrganizedTranscript(
      organized.transcript,
      preferredModel: organized.model
    )
  }

  public func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult {
    var lastError: Error?

    for model in cleanupModelOrder(for: transcript) {
      do {
        return try await organizeTranscript(
          transcript: transcript,
          dictionary: dictionary,
          model: model
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No LLM model succeeded.")
  }

  public func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String? = nil
  ) async throws -> LLMPostProcessingResult {
    var lastError: Error?
    let orderedModels = preferredModel.map {
      [$0] + modelChain.filter { $0 != preferredModel }
    } ?? modelChain

    for model in orderedModels {
      do {
        return try await analyzeTranscript(
          transcript.trimmingCharacters(in: .whitespacesAndNewlines),
          model: model
        )
      } catch {
        lastError = error
      }
    }

    throw lastError ?? WalleBrainError.invalidResponse("No LLM model succeeded.")
  }

  public func summarizeFixtureTranscript(
    _ transcript: String,
    dictionary: TermDictionary
  ) async throws -> LLMPostProcessingResult {
    try await analyzeOrganizedTranscript(transcript)
  }

  public func testConnection() async throws -> LLMPostProcessingResult {
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

    throw lastError ?? WalleBrainError.invalidResponse("No LLM model succeeded.")
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

    throw lastError ?? WalleBrainError.invalidResponse("No LLM model succeeded.")
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

    throw lastError ?? WalleBrainError.invalidResponse("No LLM model succeeded.")
  }

  private func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary,
    model: String
  ) async throws -> OrganizedTranscriptResult {
    let glossary = MeetingPostProcessingPrompts.glossaryText(from: dictionary)

    // --- Pass 1: Transcript cleanup only ---
    let cleanupPrompt = MeetingPostProcessingPrompts.organizeUserPrompt(
      transcript: transcript,
      glossary: glossary
    )

    let cleanedTranscript = try await callCompletion(
      model: model,
      systemPrompt: MeetingPostProcessingPrompts.organizeSystemPrompt,
      userPrompt: cleanupPrompt,
      maxTokens: 65536
    )

    let organizedTranscript = cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !organizedTranscript.isEmpty else {
      throw WalleBrainError.invalidResponse("Transcript cleanup returned empty text.")
    }
    try OrganizedTranscriptQualityValidator.validate(
      organizedTranscript: organizedTranscript,
      sourceTranscript: transcript
    )

    return OrganizedTranscriptResult(
      provider: providerLabel,
      model: model,
      transcript: organizedTranscript
    )
  }

  private func analyzeTranscript(
    _ transcript: String,
    model: String
  ) async throws -> LLMPostProcessingResult {
    // --- Pass 2: Analysis (summary + structured meeting memory) ---
    let analysisPrompt = MeetingPostProcessingPrompts.analysisUserPrompt(transcript: transcript)

    let analysisContent = try await callCompletion(
      model: model,
      systemPrompt: MeetingPostProcessingPrompts.analysisSystemPrompt,
      userPrompt: analysisPrompt,
      maxTokens: 8192
    )

    let jsonText = try Self.extractJSON(from: analysisContent)
    let decoded: AnalysisEnvelope
    do {
      decoded = try Self.decodeAnalysisEnvelope(from: jsonText)
    } catch {
      decoded = try await repairAnalysisEnvelope(
        invalidContent: analysisContent,
        model: model
      )
    }

    return Self.makeAnalysisResult(
      from: decoded,
      provider: providerLabel,
      model: model,
      organizedTranscript: transcript
    )
  }

  /// Parses an analysis response (the JSON shape requested by `MeetingPostProcessingPrompts.analysisUserPrompt`)
  /// into a post-processing result. Shared with backends that cannot run the API repair round-trip.
  static func parseAnalysisResult(
    content: String,
    provider: String,
    model: String,
    organizedTranscript: String
  ) throws -> LLMPostProcessingResult {
    let jsonText = try extractJSON(from: content)
    return makeAnalysisResult(
      from: try decodeAnalysisEnvelope(from: jsonText),
      provider: provider,
      model: model,
      organizedTranscript: organizedTranscript
    )
  }

  private static func makeAnalysisResult(
    from decoded: AnalysisEnvelope,
    provider: String,
    model: String,
    organizedTranscript transcript: String
  ) -> LLMPostProcessingResult {
    let filteredDecisions = filterDecisions(decoded.decisions, sourceTranscript: transcript)

    return LLMPostProcessingResult(
      provider: provider,
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

  private func repairAnalysisEnvelope(
    invalidContent: String,
    model: String
  ) async throws -> AnalysisEnvelope {
    let repairPrompt = """
    Repair the following malformed meeting-analysis response into strict JSON.
    Preserve its supported facts and use empty arrays for missing list fields.
    Output JSON only, with exactly these top-level fields:
    summary, keyPoints, actionItems, decisions, openLoops, risks,
    participantPositions, projectLinks, relatedPeople.

    Malformed response:
    \(invalidContent)
    """

    let repairedContent = try await callCompletion(
      model: model,
      systemPrompt: "You repair malformed JSON. Output strict JSON only.",
      userPrompt: repairPrompt,
      maxTokens: 8192
    )
    let repairedJSON = try Self.extractJSON(from: repairedContent)
    return try Self.decodeAnalysisEnvelope(from: repairedJSON)
  }

  private func cleanupModelOrder(for transcript: String) -> [String] {
    guard transcript.count >= 4_000 else {
      return modelChain
    }

    let proModels = modelChain.filter { $0.localizedCaseInsensitiveContains("pro") }
    guard !proModels.isEmpty else {
      return modelChain
    }
    return proModels + modelChain.filter { !proModels.contains($0) }
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
      provider: providerLabel,
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
    let filtered = Self.filterDecisions(decoded.items, sourceTranscript: transcript)

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
    let (statusCode, data) = try await performRequest(request)

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

  static func extractJSON(from content: String) throws -> String {
    if let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") {
      return String(content[start...end])
    }

    throw WalleBrainError.invalidModelPayload
  }

  private static func decodeAnalysisEnvelope(from jsonText: String) throws -> AnalysisEnvelope {
    do {
      return try JSONDecoder().decode(AnalysisEnvelope.self, from: Data(jsonText.utf8))
    } catch {
      throw WalleBrainError.invalidResponse("Analysis JSON decode failed: \(Self.describeDecodingError(error))")
    }
  }

  private static func describeDecodingError(_ error: Error) -> String {
    guard let decodingError = error as? DecodingError else {
      return error.localizedDescription
    }

    func path(_ context: DecodingError.Context) -> String {
      let value = context.codingPath.map(\.stringValue).joined(separator: ".")
      return value.isEmpty ? "<root>" : value
    }

    switch decodingError {
    case let .typeMismatch(type, context):
      return "type mismatch at \(path(context)); expected \(type): \(context.debugDescription)"
    case let .valueNotFound(type, context):
      return "missing value at \(path(context)); expected \(type): \(context.debugDescription)"
    case let .keyNotFound(key, context):
      return "missing key \(key.stringValue) at \(path(context)): \(context.debugDescription)"
    case let .dataCorrupted(context):
      return "data corrupted at \(path(context)): \(context.debugDescription)"
    @unknown default:
      return error.localizedDescription
    }
  }

  private static func resolveCompletionURL(from url: URL) -> URL {
    let path = url.path.lowercased()
    if path.hasSuffix("/chat/completions") {
      return url
    }

    return url.appending(path: "chat/completions")
  }

  private func performRequest(_ request: URLRequest) async throws -> (Int, Data) {
    var attemptSummaries: [String] = []

    for attempt in 1...NetworkTransportPolicy.maximumRequestAttempts {
      do {
        let response = try await performSingleRequestAttempt(request)
        if NetworkTransportPolicy.isTransientHTTPStatus(response.0), attempt < NetworkTransportPolicy.maximumRequestAttempts {
          attemptSummaries.append("attempt \(attempt) returned HTTP \(response.0): \(Self.responsePreview(from: response.1))")
          try await NetworkTransportPolicy.sleepBeforeRetry(attempt: attempt)
          continue
        }

        return response
      } catch {
        attemptSummaries.append("attempt \(attempt) failed: \(error.localizedDescription)")
        guard attempt < NetworkTransportPolicy.maximumRequestAttempts else {
          break
        }

        try await NetworkTransportPolicy.sleepBeforeRetry(attempt: attempt)
      }
    }

    throw WalleBrainError.invalidResponse(
      "All LLM request attempts failed. \(attemptSummaries.joined(separator: " | "))"
    )
  }

  private func performSingleRequestAttempt(_ request: URLRequest) async throws -> (Int, Data) {
    var fallbackSummaries: [String] = []

    for route in networkPolicy.urlSessionRoutes {
      do {
        return try await performURLSessionRequest(request, route: route)
      } catch {
        fallbackSummaries.append("\(route.label) failed: \(error.localizedDescription)")
      }

      do {
        return try Self.performCurlRequest(request, bypassProxy: route.bypassesProxy)
      } catch {
        let label = route.bypassesProxy ? "direct curl fallback" : "curl fallback"
        fallbackSummaries.append("\(label) failed: \(error.localizedDescription)")
      }
    }

    throw WalleBrainError.invalidResponse(fallbackSummaries.joined(separator: "; "))
  }

  private func performURLSessionRequest(
    _ request: URLRequest,
    route: NetworkTransportPolicy.URLSessionRoute
  ) async throws -> (Int, Data) {
    let (data, response) = try await route.urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WalleBrainError.invalidResponse("Missing HTTP response.")
    }

    return (httpResponse.statusCode, data)
  }

  private static func performCurlRequest(_ request: URLRequest, bypassProxy: Bool) throws -> (Int, Data) {
    guard let url = request.url else {
      throw WalleBrainError.invalidResponse("Missing request URL.")
    }

    let bodyData = request.httpBody ?? Data()
    let marker = "__WALLEBRAIN_HTTP_STATUS__:"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = [
      "-sS",
      "--max-time", "1800",
      "-X", request.httpMethod ?? "POST",
      "-H", "Authorization: \(request.value(forHTTPHeaderField: "Authorization") ?? "")",
      "-H", "Content-Type: \(request.value(forHTTPHeaderField: "Content-Type") ?? "application/json")",
      "-w", "\n\(marker)%{http_code}",
      url.absoluteString,
      "--data-binary", "@-",
    ]
    if bypassProxy {
      arguments.insert(contentsOf: ["--noproxy", "*"], at: 0)
    }
    process.arguments = arguments

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

  private static func responsePreview(from data: Data) -> String {
    let text = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count > 240 else {
      return text
    }
    return String(text.prefix(240)) + "..."
  }

  private static func filterDecisions(
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
    summary = try container.decodeRequiredLossyString(forKey: .summary)
    keyPoints = try container.decodeLossyStringArray(forKey: .keyPoints)
    actionItems = try container.decodeLossyStringArray(forKey: .actionItems)
    decisions = try container.decodeLossyArray(DecisionEnvelope.self, forKey: .decisions)
    openLoops = try container.decodeLossyArray(OpenLoopEnvelope.self, forKey: .openLoops)
    risks = try container.decodeLossyArray(RiskEnvelope.self, forKey: .risks)
    participantPositions = try container.decodeLossyArray(ParticipantPositionEnvelope.self, forKey: .participantPositions)
    projectLinks = try container.decodeLossyArray(ProjectLinkEnvelope.self, forKey: .projectLinks)
    relatedPeople = try container.decodeLossyArray(PersonEnvelope.self, forKey: .relatedPeople)
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
    text = try container.decodeRequiredLossyString(forKey: .text)
    status = container.decodeLossyRawValue(DecisionStatus.self, forKey: .status) ?? .candidate
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    relatedProjectID = try container.decodeLossyOptionalString(forKey: .relatedProjectID)
    evidence = try container.decodeLossyOptionalString(forKey: .evidence)
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
    type = container.decodeLossyRawValue(OpenLoopType.self, forKey: .type) ?? .followUp
    text = try container.decodeRequiredLossyString(forKey: .text)
    owner = try container.decodeLossyOptionalString(forKey: .owner)
    dueHint = try container.decodeLossyOptionalString(forKey: .dueHint)
    status = container.decodeLossyRawValue(OpenLoopStatus.self, forKey: .status) ?? .open
    relatedProjectID = try container.decodeLossyOptionalString(forKey: .relatedProjectID)
    evidence = try container.decodeLossyOptionalString(forKey: .evidence)
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
    text = try container.decodeRequiredLossyString(forKey: .text)
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    relatedProjectID = try container.decodeLossyOptionalString(forKey: .relatedProjectID)
    evidence = try container.decodeLossyOptionalString(forKey: .evidence)
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
    label = (try container.decodeLossyOptionalString(forKey: .label)) ?? person?.displayName ?? "参与者"
    stance = try container.decodeRequiredLossyString(forKey: .stance)
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    evidence = try container.decodeLossyOptionalString(forKey: .evidence)
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
    role = container.decodeLossyRawValue(ProjectLinkRole.self, forKey: .role) ?? .mentioned
    status = container.decodeLossyRawValue(ProjectLinkStatus.self, forKey: .status) ?? .unresolved
    confidence = try container.decodeLossyDouble(forKey: .confidence) ?? 0.5
    evidence = try container.decodeLossyOptionalString(forKey: .evidence)
  }
}

private struct ProjectEnvelope: Decodable {
  let id: String
  let title: String
  let aliases: [String]

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case name
    case aliases
  }

  init(from decoder: Decoder) throws {
    if let direct = try? LossyString(from: decoder), !direct.value.isEmpty {
      title = direct.value
      id = Self.slug(from: direct.value)
      aliases = []
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decodeFirstRequiredLossyString(forKeys: [.title, .name, .id])
    id = (try container.decodeLossyOptionalString(forKey: .id)) ?? Self.slug(from: title)
    aliases = try container.decodeLossyStringArray(forKey: .aliases)
  }

  private static func slug(from value: String) -> String {
    value
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .joined(separator: "-")
  }
}

private struct PersonEnvelope: Decodable {
  let id: String
  let displayName: String
  let aliases: [String]

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case name
    case title
    case aliases
  }

  init(from decoder: Decoder) throws {
    if let direct = try? LossyString(from: decoder), !direct.value.isEmpty {
      displayName = direct.value
      id = Self.slug(from: direct.value)
      aliases = []
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    displayName = try container.decodeFirstRequiredLossyString(forKeys: [.displayName, .name, .title, .id])
    id = (try container.decodeLossyOptionalString(forKey: .id)) ?? Self.slug(from: displayName)
    aliases = try container.decodeLossyStringArray(forKey: .aliases)
  }

  private static func slug(from value: String) -> String {
    value
      .lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .joined(separator: "-")
  }
}

private extension String {
  var nilIfBlank: String? {
    trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
  }
}

private extension KeyedDecodingContainer {
  func decodeLossyArray<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> [Value] {
    if let wrapped = try? decodeIfPresent(LossyDecodableArray<Value>.self, forKey: key) {
      return wrapped.elements
    }

    if let value = try? decodeIfPresent(Value.self, forKey: key) {
      return [value]
    }

    return []
  }

  func decodeLossyStringArray(forKey key: Key) throws -> [String] {
    try decodeLossyArray(LossyString.self, forKey: key)
      .map(\.value)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  func decodeLossyOptionalString(forKey key: Key) throws -> String? {
    guard let value = try? decodeIfPresent(LossyString.self, forKey: key)?.value else {
      return nil
    }

    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func decodeRequiredLossyString(forKey key: Key) throws -> String {
    if let value = try decodeLossyOptionalString(forKey: key) {
      return value
    }

    throw DecodingError.valueNotFound(
      String.self,
      DecodingError.Context(
        codingPath: codingPath + [key],
        debugDescription: "Expected a non-empty string-compatible value."
      )
    )
  }

  func decodeFirstRequiredLossyString(forKeys keys: [Key]) throws -> String {
    for key in keys {
      if let value = try decodeLossyOptionalString(forKey: key) {
        return value
      }
    }

    var path = codingPath
    if let firstKey = keys.first {
      path.append(firstKey)
    }

    throw DecodingError.valueNotFound(
      String.self,
      DecodingError.Context(
        codingPath: path,
        debugDescription: "Expected one of \(keys.map(\.stringValue).joined(separator: ", ")) to contain a string-compatible value."
      )
    )
  }

  func decodeLossyRawValue<Value: RawRepresentable>(_ type: Value.Type, forKey key: Key) -> Value? where Value.RawValue == String {
    guard let rawValue = try? decodeLossyOptionalString(forKey: key) else {
      return nil
    }

    return Value(rawValue: rawValue)
  }

  func decodeLossyDouble(forKey key: Key) throws -> Double? {
    if let value = try? decodeIfPresent(Double.self, forKey: key) {
      return value
    }

    if let value = try? decodeIfPresent(Int.self, forKey: key) {
      return Double(value)
    }

    if let value = try? decodeIfPresent(String.self, forKey: key) {
      return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return nil
  }
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
  let elements: [Element]

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var elements: [Element] = []

    while !container.isAtEnd {
      if let element = try? container.decode(Element.self) {
        elements.append(element)
      } else {
        _ = try? container.decode(DiscardedDecodableValue.self)
      }
    }

    self.elements = elements
  }
}

private struct LossyString: Decodable {
  let value: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self.value = value
    } else if let value = try? container.decode(Int.self) {
      self.value = String(value)
    } else if let value = try? container.decode(Double.self) {
      self.value = String(value)
    } else if let value = try? container.decode(Bool.self) {
      self.value = String(value)
    } else {
      throw DecodingError.typeMismatch(
        String.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Expected a scalar string-compatible value."
        )
      )
    }
  }
}

private struct DiscardedDecodableValue: Decodable {
  init(from decoder: Decoder) throws {
    if var container = try? decoder.unkeyedContainer() {
      while !container.isAtEnd {
        _ = try? container.decode(DiscardedDecodableValue.self)
      }
      return
    }

    if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
      for key in container.allKeys {
        _ = try? container.decode(DiscardedDecodableValue.self, forKey: key)
      }
    }
  }
}

private struct DynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}
