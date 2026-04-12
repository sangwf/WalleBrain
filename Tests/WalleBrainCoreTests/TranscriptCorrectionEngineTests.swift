import Testing
@testable import WalleBrainCore

struct TranscriptCorrectionEngineTests {
  @Test
  func appliesSessionCorrectionsAndOverridesMemory() {
    let engine = TranscriptCorrectionEngine()
    let transcript = "神车和付姐一起看神车平台。"

    let output = engine.apply(
      to: transcript,
      sessionCorrections: [
        TranscriptCorrection(wrong: "付姐", correct: "付杰", type: "person"),
        TranscriptCorrection(wrong: "神车", correct: "神策", type: "company"),
      ],
      memoryEntries: [
        CorrectionMemoryEntry(wrong: "神车", correct: "神册", type: "company"),
      ]
    )

    #expect(output == "神策和付杰一起看神策平台。")
  }

  @Test
  func prefersLongerWrongTermsFirst() {
    let engine = TranscriptCorrectionEngine()
    let transcript = "香港Hong Kong T项目延期。"

    let output = engine.apply(
      to: transcript,
      sessionCorrections: [
        TranscriptCorrection(wrong: "Hong Kong T", correct: "Hong Kong Telecom", type: "project"),
        TranscriptCorrection(wrong: "Hong Kong", correct: "HK", type: "project"),
      ],
      memoryEntries: []
    )

    #expect(output == "香港Hong Kong Telecom项目延期。")
  }
}
