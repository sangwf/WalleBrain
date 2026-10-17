import Testing
@testable import WalleBrainCore

struct OrganizedTranscriptQualityValidatorTests {
  @Test
  func acceptsReadableChineseCleanup() throws {
    let source = String(repeating: "神策正在讨论AI增长团队、客户世界模型和企业服务市场。", count: 30)
    let organized = (0 ..< 18)
      .map { "A：第\($0 + 1)部分讨论神策AI增长团队与客户世界模型。" }
      .joined(separator: "\n")

    let report = try OrganizedTranscriptQualityValidator.validate(
      organizedTranscript: organized,
      sourceTranscript: source
    )

    #expect(report.lengthRatio >= 0.35)
    #expect(report.organizedChineseRatio >= 0.35)
  }

  @Test
  func rejectsModelDeliberation() {
    let source = String(repeating: "这是一次关于企业人工智能战略的中文会议。", count: 40)
    let organized = String(repeating: "Let's search memory. What about \"Devin\"? ", count: 30)

    #expect(throws: Error.self) {
      try OrganizedTranscriptQualityValidator.validate(
        organizedTranscript: organized,
        sourceTranscript: source
      )
    }
  }

  @Test
  func rejectsLongRepeatedSentences() {
    let source = String(repeating: "会议讨论了市场、产品、客户和融资安排。", count: 60)
    let repeated = "这是一段长度足够长而且不应该在整理稿中连续重复出现三次的模型输出内容"
    let organized = "\(repeated)。\(repeated)。\(repeated)。"

    #expect(throws: Error.self) {
      try OrganizedTranscriptQualityValidator.validate(
        organizedTranscript: organized,
        sourceTranscript: source
      )
    }
  }

  @Test
  func acceptsEnglishMeetingWithoutChineseThreshold() throws {
    let source = String(repeating: "The team discussed product strategy, customers, and financing. ", count: 30)
    let organized = (0 ..< 20)
      .map { "Speaker A, turn \($0 + 1): The team discussed product strategy and financing." }
      .joined(separator: "\n")

    let report = try OrganizedTranscriptQualityValidator.validate(
      organizedTranscript: organized,
      sourceTranscript: source
    )

    #expect(report.sourceChineseRatio == 0)
    #expect(report.organizedChineseRatio == 0)
  }

  @Test
  func rejectsSevereContentLoss() {
    let source = String(repeating: "会议讨论了产品、客户、市场、团队和融资计划。", count: 100)

    #expect(throws: Error.self) {
      try OrganizedTranscriptQualityValidator.validate(
        organizedTranscript: "会议结束。",
        sourceTranscript: source
      )
    }
  }
}
