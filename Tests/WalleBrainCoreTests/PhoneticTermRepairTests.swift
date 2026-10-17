import Testing
@testable import WalleBrainCore

struct PhoneticTermRepairTests {
  private let repair = PhoneticTermRepair(phrases: ["神策", "付杰", "房东雨", "东雨", "WalleBrain"])

  @Test
  func repairsObservedMisrecognitionsOfDictionaryTerms() {
    // Real Apple Speech outputs from a recorded meeting.
    #expect(repair.apply(to: "我们神车的产品") == "我们神策的产品")
    #expect(repair.apply(to: "其实就是神特因为从15年成立") == "其实就是神策因为从15年成立")
    #expect(repair.apply(to: "对神者来说") == "对神策来说")
    #expect(repair.apply(to: "那对神着来说") == "那对神策来说")
    #expect(repair.apply(to: "傅杰说下周上线") == "付杰说下周上线")
  }

  @Test
  func reportsEachReplacement() {
    let result = repair.repair("神车和神者都是神策")

    #expect(result.text == "神策和神策都是神策")
    #expect(result.replacements == [
      .init(original: "神车", replacement: "神策"),
      .init(original: "神者", replacement: "神策"),
    ])
  }

  @Test
  func leavesRealWordsAndWordInteriorsAlone() {
    for text in ["当地的政策问题", "回到家乡了", "精神车间", "神色凝重", "冬雨很冷"] {
      let guarded = PhoneticTermRepair(phrases: ["神策", "家祥", "东雨"])
      #expect(guarded.apply(to: text) == text)
    }
  }

  @Test
  func requiresAnAnchorCharacterAndSimilarSyllables() {
    // No character in common with the term.
    #expect(repair.apply(to: "身侧") == "身侧")
    // Shares a character, but the other syllable is not a near-homophone.
    #expect(repair.apply(to: "神奇的效果") == "神奇的效果")
  }

  @Test
  func prefersLongerTermsAndKeepsCorrectTermsUntouched() {
    #expect(repair.apply(to: "房东与负责运维") == "房东雨负责运维")
    #expect(repair.apply(to: "房东雨和神策") == "房东雨和神策")
  }

  @Test
  func ignoresNonChineseTermsAndText() {
    let englishOnly = PhoneticTermRepair(phrases: ["WalleBrain", "CRM"])

    #expect(englishOnly.targetCount == 0)
    #expect(englishOnly.apply(to: "神车 wall brain") == "神车 wall brain")
    #expect(repair.apply(to: "growth agent and AI worker") == "growth agent and AI worker")
  }
}
