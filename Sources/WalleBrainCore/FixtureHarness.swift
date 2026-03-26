import Foundation

public actor FixtureHarness {
  private let paths: RuntimePaths
  private let dictionaryStore: TermDictionaryStore
  private let compiler: CustomLanguageModelCompiler
  private let exporter: NoteExporter

  public init(paths: RuntimePaths) {
    self.paths = paths
    self.dictionaryStore = TermDictionaryStore(paths: paths)
    self.compiler = CustomLanguageModelCompiler(paths: paths)
    self.exporter = NoteExporter(paths: paths)
  }

  public func run(transcript: String) async throws -> FixtureHarnessResult {
    let dictionaryPath = try await dictionaryStore.ensureExists()
    let dictionary = try await dictionaryStore.loadDictionary()
    let assets = try await compiler.compile(dictionary: dictionary)
    let deerAPI = try await DeerAPIClient().summarize(transcript: transcript, dictionary: dictionary)

    let notePath = try await exporter.export(
      note: NativeMeetingNote(
        title: "WalleBrain Native Harness",
        startedAt: Date(),
        endedAt: Date(),
        transcript: transcript,
        liveTranscript: transcript,
        summary: deerAPI.summary,
        organizedTranscript: deerAPI.organizedTranscript,
        keyPoints: deerAPI.keyPoints,
        actionItems: deerAPI.actionItems,
        dictionaryPath: dictionaryPath.path(percentEncoded: false),
        audioFilePath: "",
        provider: deerAPI.provider,
        model: deerAPI.model
      )
    )

    return FixtureHarnessResult(
      dictionaryPath: dictionaryPath,
      assets: assets,
      notePath: notePath,
      deerAPI: deerAPI
    )
  }
}
