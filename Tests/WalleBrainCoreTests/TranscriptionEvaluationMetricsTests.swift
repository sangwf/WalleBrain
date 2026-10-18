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

  @Test
  func countsDictionaryTermMentionsReproducedByTranscript() {
    let counts = TranscriptionEvaluationMetrics.termMentionCounts(
      expected: "神策的张俊峰说，神策 CRM 上线了",
      actual: "神车的俊峰说，神策crm上线了，神策，神策",
      terms: ["神策", "张俊峰", "俊峰", "CRM"]
    )

    #expect(counts.expected == 4)
    #expect(counts.matched == 3)
  }
}
