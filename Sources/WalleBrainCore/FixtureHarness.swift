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
    let llmResult = try await LLMChatClient().summarize(transcript: transcript, dictionary: dictionary)

    let notePath = try await exporter.export(
      note: NativeMeetingNote(
        title: "WalleBrain Native Harness",
        startedAt: Date(),
        endedAt: Date(),
        transcript: transcript,
        liveTranscript: transcript,
        summary: llmResult.summary,
        organizedTranscript: llmResult.organizedTranscript,
        keyPoints: llmResult.keyPoints,
        actionItems: llmResult.actionItems,
        dictionaryPath: dictionaryPath.path(percentEncoded: false),
        audioFilePath: "",
        provider: llmResult.provider,
        model: llmResult.model
      )
    )

    return FixtureHarnessResult(
      dictionaryPath: dictionaryPath,
      assets: assets,
      notePath: notePath,
      llmResult: llmResult
    )
  }
}
