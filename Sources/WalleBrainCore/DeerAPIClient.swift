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

  public func testConnection() async throws -> DeerAPIResult {
    try await summarize(
      transcript: "这是一次连接测试。",
      dictionary: TermDictionary(title: "Connection Test", entries: [])
    )
  }

  private func summarize(
    transcript: String,
    dictionary: TermDictionary,
    model: String,
  ) async throws -> DeerAPIResult {
    let glossary = dictionary.entries.map { entry in
      let aliases = entry.aliases.isEmpty ? "" : " aliases=\(entry.aliases.joined(separator: ", "))"
      let type = entry.type.map { " type=\($0)" } ?? ""
      let notes = entry.notes.map { " notes=\($0)" } ?? ""
      return "- \(entry.canonical)\(aliases)\(type)\(notes)"
    }.joined(separator: "\n")

    // --- Pass 1: Transcript cleanup only ---
    let cleanupPrompt = """
    You are a Chinese transcript editor producing a readable meeting record.

    Glossary (for correcting misrecognized terms):
    \(glossary)

    Raw transcript:
    \(transcript)

    TASK: Produce an organized transcript that is easy to read but preserves all substantive content.

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

    Style:
    - Label speakers A:/B: with each turn as a separate paragraph.
    - Lightly smooth incomplete sentences into complete ones, but keep the speaker's vocabulary.
    - Do NOT rewrite in formal/written style — it should still read like a conversation, just a clean one.
    - Fix ASR misrecognitions using context and the glossary.
    - Use simplified Chinese.
    - Output plain text only, no JSON, no markdown.
    """

    let cleanedTranscript = try await callCompletion(
      model: model,
      systemPrompt: "You are a transcript editor. Output cleaned text only, no JSON, no markdown fencing.",
      userPrompt: cleanupPrompt,
      maxTokens: 65536
    )

    // --- Pass 2: Analysis (summary, key points, action items) ---
    let analysisPrompt = """
    You are preparing a Chinese meeting note from the following transcript.

    Transcript:
    \(cleanedTranscript)

    Return strict JSON with this shape:
    {
      "summary": "string",
      "keyPoints": ["string"],
      "actionItems": ["string"]
    }

    Requirements:
    - Use simplified Chinese.
    - summary: A comprehensive paragraph covering all major topics discussed.
    - keyPoints: Concrete, specific points with numbers and details where available.
    - actionItems: Specific next steps with who is responsible.
    - Do not invent facts not in the transcript.
    """

    let analysisContent = try await callCompletion(
      model: model,
      systemPrompt: "You output strict JSON only.",
      userPrompt: analysisPrompt,
      maxTokens: 4096
    )

    let jsonText = try Self.extractJSON(from: analysisContent)
    let decoded = try JSONDecoder().decode(AnalysisEnvelope.self, from: Data(jsonText.utf8))

    return DeerAPIResult(
      provider: "deerapi",
      model: model,
      summary: decoded.summary,
      organizedTranscript: cleanedTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
      keyPoints: decoded.keyPoints,
      actionItems: decoded.actionItems
    )
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

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WalleBrainError.invalidResponse("Missing HTTP response.")
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw WalleBrainError.invalidResponse(
        "HTTP \(httpResponse.statusCode): \(String(decoding: data, as: UTF8.self))"
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
}

private struct AnalysisEnvelope: Decodable {
  let summary: String
  let keyPoints: [String]
  let actionItems: [String]
}
