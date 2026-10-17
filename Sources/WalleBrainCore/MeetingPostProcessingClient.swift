public protocol MeetingPostProcessingClient: Sendable {
  func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult

  func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult

  /// Whether `preferredModel` (usually the model that organized the transcript) is meaningful to this client.
  /// A fallback client uses this to avoid sending one backend's model name to another backend.
  func acceptsPreferredModel(_ model: String) async -> Bool
}

extension MeetingPostProcessingClient {
  public func acceptsPreferredModel(_ model: String) async -> Bool {
    true
  }
}

extension LLMChatClient: MeetingPostProcessingClient {
  public func acceptsPreferredModel(_ model: String) async -> Bool {
    configuredModels.contains(model)
  }
}
