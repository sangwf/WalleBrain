import Testing
@testable import WalleBrainCore

struct OpenAIRealtimeTranscriptionClientTests {
  @Test
  func rotatesBeforeRealtimeSessionLimit() {
    #expect(OpenAIRealtimeTranscriptionClient.proactiveRealtimeSessionRotationSeconds < OpenAIRealtimeTranscriptionClient.maximumRealtimeSessionDurationSeconds)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRotateRealtimeSession(afterAudioSeconds: OpenAIRealtimeTranscriptionClient.proactiveRealtimeSessionRotationSeconds - 1) == false)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRotateRealtimeSession(afterAudioSeconds: OpenAIRealtimeTranscriptionClient.proactiveRealtimeSessionRotationSeconds) == true)
  }

  @Test
  func commitsAudioOftenEnoughForLiveTranscription() {
    #expect(OpenAIRealtimeTranscriptionClient.commitIntervalSeconds <= 3.0)
    #expect(OpenAIRealtimeTranscriptionClient.commitIntervalSeconds >= 1.5)
  }
}
