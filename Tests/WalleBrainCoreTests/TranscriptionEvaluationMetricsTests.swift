import Testing
@testable import WalleBrainCore

struct TranscriptionEvaluationMetricsTests {
  @Test
  func normalizesChineseWhitespacePunctuationAndCase() {
    let expected = "我想用百度搜索短信"
    let actual = "我 想 用 百度，搜索短信！"

    #expect(TranscriptionEvaluationMetrics.normalizeTextForComparison(actual) == expected)
    #expect(TranscriptionEvaluationMetrics.isNormalizedExactMatch(expected: expected, actual: actual))
  }

  @Test
  func computesCharacterErrorRateForSubstitution() {
    let rate = TranscriptionEvaluationMetrics.characterErrorRate(
      expected: "高德地图",
      actual: "高的地图"
    )

    #expect(rate == 0.25)
  }

  @Test
  func capsCharacterErrorRateAtOne() {
    let rate = TranscriptionEvaluationMetrics.characterErrorRate(
      expected: "好",
      actual: "完全不一样"
    )

    #expect(rate == 1)
  }
}
