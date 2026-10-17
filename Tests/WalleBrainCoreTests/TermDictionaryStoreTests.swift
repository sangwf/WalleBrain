import Foundation
import Testing
@testable import WalleBrainCore

struct TermDictionaryStoreTests {
  /// Same shape as the user's real Business Dictionary: people nested under a company with `###`,
  /// full-width `：`, `、`-separated aliases, and an empty alias list.
  private let realShapedMarkdown = """
  # Business Dictionary

  ## WalleBrain
  - aliases: wall brain
  - type: product
  - notes: Native macOS meeting assistant

  ## 神策
  - notes：公司名称

  ### 张俊峰
  - aliases: 俊峰
  - notes: 市场部负责人，西南经营单元负责人

  ### 房东雨
  - aliases: 房东、东雨
  - notes: 运维团队负责人

  ### 付杰
  - aliases:
  - notes: 国际化团队负责人
  """

  @Test
  func nestedHeadingsBecomeTheirOwnEntries() throws {
    let dictionary = try TermDictionaryStore.parse(markdown: realShapedMarkdown)

    #expect(dictionary.title == "Business Dictionary")
    #expect(dictionary.entries.map(\.canonical) == ["WalleBrain", "神策", "张俊峰", "房东雨", "付杰"])
    #expect(dictionary.allTerms.contains("付杰"))
    #expect(dictionary.allTerms.contains("东雨"))
  }

  @Test
  func fullWidthColonIsAKeySeparator() throws {
    let dictionary = try TermDictionaryStore.parse(markdown: realShapedMarkdown)
    let company = try #require(dictionary.entries.first { $0.canonical == "神策" })

    #expect(company.notes == "公司名称")
    #expect(company.aliases.isEmpty)
  }

  @Test
  func aliasesSplitOnChineseSeparatorsAndSkipEmptyLists() throws {
    let dictionary = try TermDictionaryStore.parse(markdown: realShapedMarkdown)
    let entries = Dictionary(uniqueKeysWithValues: dictionary.entries.map { ($0.canonical, $0) })

    #expect(entries["房东雨"]?.aliases == ["房东", "东雨"])
    #expect(entries["张俊峰"]?.aliases == ["俊峰"])
    #expect(entries["付杰"]?.aliases == [])

    let mixed = try TermDictionaryStore.parse(markdown: "## 神策\n- aliases: Sensors Data，神策数据、SA, sensors")
    #expect(mixed.entries.first?.aliases == ["Sensors Data", "神策数据", "SA", "sensors"])
  }

  @Test
  func nestedEntriesRecordTheirParentHeading() throws {
    let dictionary = try TermDictionaryStore.parse(markdown: realShapedMarkdown)
    let entries = Dictionary(uniqueKeysWithValues: dictionary.entries.map { ($0.canonical, $0) })

    #expect(entries["张俊峰"]?.notes == "市场部负责人，西南经营单元负责人; parent: 神策")
    #expect(entries["房东雨"]?.notes == "运维团队负责人; parent: 神策")
    #expect(entries["神策"]?.notes == "公司名称")
    #expect(entries["WalleBrain"]?.notes == "Native macOS meeting assistant")
  }

  @Test
  func parentTrackingFollowsHeadingLevels() throws {
    let dictionary = try TermDictionaryStore.parse(markdown: """
    ## A
    ### A1
    #### A1x
    ### A2
    ## B
    ### B1
    """)
    let notes = dictionary.entries.map { "\($0.canonical)=\($0.notes ?? "")" }

    #expect(notes == ["A=", "A1=parent: A", "A1x=parent: A1", "A2=parent: A", "B=", "B1=parent: B"])
  }

  @Test
  func topLevelEntriesParseAsBefore() throws {
    let dictionary = try TermDictionaryStore.parse(markdown: TermDictionaryStore.sampleMarkdown)

    #expect(
      dictionary.entries == [
        TermEntry(canonical: "WalleBrain", aliases: ["wall brain"], type: "product", notes: "Native macOS meeting assistant"),
        TermEntry(canonical: "LLM", aliases: ["deer api"], type: "service", notes: "Model gateway used for post-processing"),
        TermEntry(canonical: "CRM", aliases: ["c r m"], type: "business", notes: "Customer relationship management system"),
      ]
    )
  }

  @Test
  func headingsWithoutASpaceAreNotEntries() {
    #expect(throws: WalleBrainError.self) {
      try TermDictionaryStore.parse(markdown: "# Title\n##NotAnEntry\n- aliases: x")
    }
  }
}
