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
    var request = URLRequest(url: completionURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let glossary = dictionary.entries.map { entry in
      let aliases = entry.aliases.isEmpty ? "" : " aliases=\(entry.aliases.joined(separator: ", "))"
      let type = entry.type.map { " type=\($0)" } ?? ""
      let notes = entry.notes.map { " notes=\($0)" } ?? ""
      return "- \(entry.canonical)\(aliases)\(type)\(notes)"
    }.joined(separator: "\n")

    let prompt = """
    You are preparing a Chinese meeting note.

    Respect this glossary when normalizing names, but do not invent content:
    \(glossary)

    Transcript:
    \(transcript)

    Requirements:
    - Use simplified Chinese.
    - `organizedTranscript` must be a faithful cleanup of the transcript, not a summary.
    - Preserve meaning and rough order.
    - Add punctuation and paragraph breaks.
    - Remove only obvious ASR duplication or filler when it is clearly redundant.
    - Do not invent facts, names, or decisions that are not supported by the transcript.

    Return strict JSON with this shape:
    {
      "summary": "string",
      "organizedTranscript": "string",
      "keyPoints": ["string"],
      "actionItems": ["string"]
    }
    """

    let body: [String: Any] = [
      "model": model,
      "messages": [
        [
          "role": "system",
          "content": "You output strict JSON only.",
        ],
        [
          "role": "user",
          "content": prompt,
        ],
      ],
      "temperature": 0.2,
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

    let jsonText = try Self.extractJSON(from: content)
    let decoded = try JSONDecoder().decode(LLMEnvelope.self, from: Data(jsonText.utf8))
    let actualModel = (payload?["model"] as? String) ?? model

    return DeerAPIResult(
      provider: "deerapi",
      model: actualModel,
      summary: decoded.summary,
      organizedTranscript: normalizedOrganizedTranscript(
        decoded.organizedTranscript,
        fallback: transcript
      ),
      keyPoints: decoded.keyPoints,
      actionItems: decoded.actionItems
    )
  }

  private func normalizedOrganizedTranscript(_ value: String?, fallback: String) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      return fallback
    }
    return trimmed
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

private struct LLMEnvelope: Decodable {
  let summary: String
  let organizedTranscript: String?
  let keyPoints: [String]
  let actionItems: [String]
}
