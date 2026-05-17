import Testing
@testable import WalleBrainCore

struct OpenAIRealtimeTranscriptionClientTests {
  @Test
  func rotatesBeforeRealtimeSessionLimit() {
    #expect(OpenAIRealtimeTranscriptionClient.proactiveRealtimeSessionRotationSeconds < OpenAIRealtimeTranscriptionClient.maximumRealtimeSessionDurationSeconds)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRotateRealtimeSession(afterAudioSeconds: OpenAIRealtimeTranscriptionClient.proactiveRealtimeSessionRotationSeconds - 1) == false)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRotateRealtimeSession(afterAudioSeconds: OpenAIRealtimeTranscriptionClient.proactiveRealtimeSessionRotationSeconds) == true)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRotateRealtimeSession(afterWallClockDuration: .seconds(44 * 60)) == false)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRotateRealtimeSession(afterWallClockDuration: .seconds(45 * 60)) == true)
  }

  @Test
  func recoversNearRotationConnectionCloseByRotating() {
    #expect(OpenAIRealtimeTranscriptionClient.shouldRecoverRealtimeSessionAfterConnectionClose(
      wallClockDuration: .seconds(39 * 60),
      audioSeconds: 0
    ) == false)
    #expect(OpenAIRealtimeTranscriptionClient.shouldRecoverRealtimeSessionAfterConnectionClose(
      wallClockDuration: .seconds(40 * 60),
      audioSeconds: 0
    ) == true)
  }

  @Test
  func commitsAudioOftenEnoughForLiveTranscription() {
    #expect(OpenAIRealtimeTranscriptionClient.commitIntervalSeconds <= 3.0)
    #expect(OpenAIRealtimeTranscriptionClient.commitIntervalSeconds >= 1.5)
  }

  @Test
  func realtimeUsesSharedSystemThenDirectNetworkPolicy() {
    let policy = NetworkTransportPolicy.realtimeDefault()

    #expect(policy.urlSessionRoutes.count == 2)
    #expect(policy.urlSessionRoutes[0].bypassesProxy == false)
    #expect(policy.urlSessionRoutes[1].bypassesProxy == true)
  }
}
