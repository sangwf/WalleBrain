import Foundation
import WalleBrainCore

@main
struct WalleBrainReprocessSession {
  static func main() async throws {
    let arguments = CommandLine.arguments
    let organizeOnly = arguments.contains("--organize-only")
    let backendArgument = arguments.first { $0.hasPrefix("--backend=") }?.dropFirst("--backend=".count)
    let backend = backendArgument.flatMap { PostProcessingBackend(rawValue: String($0)) }
    let positionalArguments = arguments.dropFirst().filter { !$0.hasPrefix("--") }
    guard let sessionPath = positionalArguments.first, backendArgument == nil || backend != nil else {
      fputs("Usage: swift run WalleBrainReprocessSession [--organize-only] [--backend=codex|api] <session-json-path>\n", stderr)
      Foundation.exit(2)
    }
    let client = try MeetingPostProcessingClientFactory.makeClient(
      backend: backend,
      log: PostProcessingLog.unifiedLogAndStandardError
    )

    let sessionURL = URL(fileURLWithPath: sessionPath)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    let data = try Data(contentsOf: sessionURL)
    var session = try decoder.decode(NativeMeetingSession.self, from: data)

    let paths = RuntimePaths()
    if organizeOnly {
      session = try await organizeSession(session, paths: paths, client: client)
    } else {
      session = try await MeetingPostProcessor(paths: paths, client: client).process(session)
    }

    try await MeetingSessionStore(paths: paths).save(session)

    let output: [String: String] = [
      "status": session.status.rawValue,
      "provider": session.provider ?? "",
      "model": session.model ?? "",
      "notePath": session.exportedNotePath ?? "",
      "error": session.errorMessage ?? ""
    ]
    let outputData = try encoder.encode(output)
    FileHandle.standardOutput.write(outputData)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }

  private static func organizeSession(
    _ session: NativeMeetingSession,
    paths: RuntimePaths,
    client: any MeetingPostProcessingClient
  ) async throws -> NativeMeetingSession {
    var session = session
    let sourceTranscript = session.correctedTranscript?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveTranscript = sourceTranscript?.isEmpty == false
      ? sourceTranscript!
      : session.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !effectiveTranscript.isEmpty else {
      throw WalleBrainError.invalidResponse("Cannot organize an empty transcript.")
    }

    let dictionaryURL = URL(fileURLWithPath: session.dictionaryPath)
    let dictionary: TermDictionary
    if FileManager.default.fileExists(atPath: dictionaryURL.path(percentEncoded: false)) {
      let markdown = try String(contentsOf: dictionaryURL, encoding: .utf8)
      dictionary = try TermDictionaryStore.parse(markdown: markdown)
    } else {
      dictionary = try await TermDictionaryStore(paths: paths).loadDictionary()
    }

    let result = try await client.organizeTranscript(
      transcript: effectiveTranscript,
      dictionary: dictionary
    )
    try OrganizedTranscriptQualityValidator.validate(
      organizedTranscript: result.transcript,
      sourceTranscript: effectiveTranscript
    )

    session.organizedTranscript = result.transcript
    session.summary = "整理稿已重新生成；结构化摘要与要点未在本次恢复中生成。"
    session.keyPoints = []
    session.actionItems = []
    session.decisions = []
    session.openLoops = []
    session.risks = []
    session.participantPositions = []
    session.projectLinks = []
    session.relatedPeople = []
    session.provider = result.provider
    session.model = result.model
    session.status = .exported
    session.errorMessage = nil

    let notePath = try await NoteExporter(paths: paths).export(
      note: NativeMeetingNote(
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        transcript: effectiveTranscript,
        liveTranscript: session.liveTranscript,
        summary: session.summary ?? "",
        organizedTranscript: result.transcript,
        keyPoints: session.keyPoints,
        actionItems: session.actionItems,
        decisions: session.decisions ?? [],
        openLoops: session.openLoops ?? [],
        risks: session.risks ?? [],
        participantPositions: session.participantPositions ?? [],
        projectLinks: session.projectLinks ?? [],
        relatedPeople: session.relatedPeople ?? [],
        dictionaryPath: session.dictionaryPath,
        audioFilePath: session.audioFilePath,
        provider: result.provider,
        model: result.model
      )
    )
    session.exportedNotePath = notePath.path(percentEncoded: false)
    return session
  }

}
