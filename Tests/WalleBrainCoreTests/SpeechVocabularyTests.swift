import Foundation
import Testing
@testable import WalleBrainCore

struct SpeechVocabularyTests {
  private let dictionary = TermDictionary(
    title: "Business Dictionary",
    entries: [
      TermEntry(canonical: "神策", aliases: ["Sensors Data", " sensors   data "], type: "company", notes: "公司名称"),
      TermEntry(canonical: "WalleBrain", aliases: ["wall brain", ""], type: "product", notes: nil),
      TermEntry(canonical: "CRM", aliases: ["c r m", "crm"], type: nil, notes: nil),
    ]
  )

  @Test
  func contextualStringsListCanonicalTermsFirstWithoutDuplicates() {
    #expect(
      SpeechVocabulary.contextualStrings(from: dictionary)
        == ["神策", "WalleBrain", "CRM", "Sensors Data", "wall brain", "c r m"]
    )
    #expect(SpeechVocabulary.contextualStrings(from: dictionary, limit: 2) == ["神策", "WalleBrain"])
  }

  @Test
  func weightedPhrasesFavorCanonicalTerms() {
    let phrases = SpeechVocabulary.weightedPhrases(from: dictionary)

    #expect(phrases.map(\.phrase) == ["神策", "WalleBrain", "CRM", "Sensors Data", "wall brain", "c r m"])
    #expect(phrases.prefix(3).allSatisfy { $0.count == SpeechVocabulary.canonicalPhraseCount })
    #expect(phrases.dropFirst(3).allSatisfy { $0.count == SpeechVocabulary.aliasPhraseCount })
  }

  @Test
  func cacheKeyIsStableAndIgnoresNotesAndType() {
    let key = SpeechVocabulary.cacheKey(for: dictionary, localeIdentifier: "zh_CN")
    let annotated = TermDictionary(
      title: "Renamed",
      entries: dictionary.entries.map {
        TermEntry(canonical: $0.canonical, aliases: $0.aliases, type: "other", notes: "edited notes")
      }
    )

    #expect(key.count == 16)
    #expect(key.allSatisfy { $0.isHexDigit })
    #expect(key == SpeechVocabulary.cacheKey(for: dictionary, localeIdentifier: "zh-CN"))
    #expect(key == SpeechVocabulary.cacheKey(for: annotated, localeIdentifier: "zh_CN"))
  }

  @Test
  func cacheKeyChangesWhenRecognitionInputsChange() {
    let key = SpeechVocabulary.cacheKey(for: dictionary, localeIdentifier: "zh_CN")
    let withNewAlias = TermDictionary(
      title: dictionary.title,
      entries: dictionary.entries + [TermEntry(canonical: "付杰", aliases: [], type: nil, notes: nil)]
    )

    #expect(key != SpeechVocabulary.cacheKey(for: dictionary, localeIdentifier: "en_US"))
    #expect(key != SpeechVocabulary.cacheKey(for: withNewAlias, localeIdentifier: "zh_CN"))
  }

  @Test
  func compilerReusesCachedAssetsAndPrunesStaleVersions() async throws {
    let paths = RuntimePaths(baseDirectory: makeTemporaryBaseDirectory())
    try paths.ensureDirectories()
    let locale = Locale(identifier: "zh_CN")
    let version = SpeechVocabulary.cacheKey(for: dictionary, localeIdentifier: locale.identifier)
    let stem = "com.wallebrain.dictionary.zh_CN"
    for suffix in ["asset", "lm", "vocab"] {
      try Data("cached".utf8).write(to: paths.speechAssetsDirectory.appending(path: "\(stem).\(version).\(suffix)"))
      try Data("stale".utf8).write(to: paths.speechAssetsDirectory.appending(path: "\(stem).1234.\(suffix)"))
    }
    let otherLocale = paths.speechAssetsDirectory.appending(path: "com.wallebrain.dictionary.en_US.1234.lm")
    try Data("other".utf8).write(to: otherLocale)

    let assets = try await CustomLanguageModelCompiler(paths: paths).compile(dictionary: dictionary, locale: locale)

    #expect(assets.languageModelURL.lastPathComponent == "\(stem).\(version).lm")
    let cachedModel = try String(contentsOf: assets.languageModelURL, encoding: .utf8)
    #expect(cachedModel == "cached")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: paths.speechAssetsDirectory.path(percentEncoded: false))
    #expect(remaining.filter { $0.hasPrefix("\(stem).") }.sorted() == ["asset", "lm", "vocab"].map { "\(stem).\(version).\($0)" })
    #expect(remaining.contains(otherLocale.lastPathComponent))
  }

  @Test
  func liveVocabularyCombinesContextualStringsAndRepair() {
    let vocabulary = LiveSpeechVocabulary(dictionary: dictionary)

    #expect(vocabulary.contextualStrings.first == "神策")
    #expect(vocabulary.termRepair.apply(to: "其实就是神特因为") == "其实就是神策因为")
    #expect(LiveSpeechVocabulary.empty.contextualStrings.isEmpty)
    #expect(LiveSpeechVocabulary.empty.termRepair.apply(to: "其实就是神特因为") == "其实就是神特因为")
  }

  private func makeTemporaryBaseDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "WalleBrainTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
