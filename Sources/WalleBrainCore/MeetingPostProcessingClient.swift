public protocol MeetingPostProcessingClient: Sendable {
  func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult

  func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult
}

extension LLMChatClient: MeetingPostProcessingClient {}
