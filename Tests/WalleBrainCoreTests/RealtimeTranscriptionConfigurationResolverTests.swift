import Testing
@testable import WalleBrainCore

struct RealtimeTranscriptionConfigurationResolverTests {
  @Test
  func resolvesOpenAIAPIKeyFromEnvironment() throws {
    let resolver = RealtimeTranscriptionConfigurationResolver(
      mergedEnvironment: [
        "OPENAI_API_KEY": "realtime-secret",
      ]
    )

    let resolved = try resolver.resolve()

    #expect(resolved.apiKey == "realtime-secret")
    #expect(resolved.model == RealtimeTranscriptionConfiguration.defaultModel)
    #expect(resolved.provider == RealtimeTranscriptionConfiguration.defaultProvider)
  }

  @Test
  func allowsRealtimeModelOverrideForNewOpenAIModelIDs() throws {
    let resolver = RealtimeTranscriptionConfigurationResolver(
      mergedEnvironment: [
        "OPENAI_API_KEY": "realtime-secret",
        "WALLEBRAIN_REALTIME_TRANSCRIPTION_MODEL": "gpt-realtime-whisper-2026-05-07",
      ]
    )

    let resolved = try resolver.resolve()

    #expect(resolved.model == "gpt-realtime-whisper-2026-05-07")
  }

  @Test
  func previewFlagsMissingOpenAIAPIKey() {
    let resolver = RealtimeTranscriptionConfigurationResolver(mergedEnvironment: [:])

    let preview = resolver.preview()

    #expect(preview.apiKey.errorMessage == "Environment variable OPENAI_API_KEY is not set.")
    #expect(preview.isValid == false)
  }
}
