import Foundation

public actor MeetingPostProcessor {
  private let paths: RuntimePaths
  private let dictionaryStore: TermDictionaryStore
  private let correctionMemoryStore: CorrectionMemoryStore
  private let exporter: NoteExporter
  private let correctionEngine = TranscriptCorrectionEngine()

  public init(paths: RuntimePaths) {
    self.paths = paths
    self.dictionaryStore = TermDictionaryStore(paths: paths)
    self.correctionMemoryStore = CorrectionMemoryStore(paths: paths)
    self.exporter = NoteExporter(paths: paths)
  }

  public func process(_ session: NativeMeetingSession) async throws -> NativeMeetingSession {
    var session = session
    let dictionary = try await loadDictionary(for: session)
    let memoryEntries = (try? await correctionMemoryStore.load()) ?? []
    let correctedTranscript = correctionEngine.apply(
      to: session.liveTranscript,
      sessionCorrections: session.sessionCorrections ?? [],
      memoryEntries: memoryEntries
    )
    let effectiveTranscript = correctedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? session.liveTranscript
      : correctedTranscript
    session.correctedTranscript = effectiveTranscript

    let result: DeerAPIResult
    let aiSucceeded: Bool
    if effectiveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      result = DeerAPIResult(
        provider: "local",
        model: "empty-transcript",
        summary: "No speech was captured in this meeting.",
        organizedTranscript: "No speech was captured in this meeting.",
        keyPoints: [],
        actionItems: [],
        openLoops: []
      )
      aiSucceeded = true
    } else {
      do {
        result = try await DeerAPIClient().summarize(transcript: effectiveTranscript, dictionary: dictionary)
        aiSucceeded = true
      } catch {
        result = fallbackResult(for: effectiveTranscript, error: error)
        aiSucceeded = false
        session.errorMessage = error.localizedDescription
      }
    }

    let notePath = try await exporter.export(
      note: NativeMeetingNote(
        title: session.title,
        startedAt: session.startedAt,
        endedAt: session.endedAt,
        transcript: effectiveTranscript,
        liveTranscript: session.liveTranscript,
        summary: result.summary,
        organizedTranscript: result.organizedTranscript,
        keyPoints: result.keyPoints,
        actionItems: result.actionItems,
        decisions: result.decisions,
        openLoops: result.openLoops,
        risks: result.risks,
        participantPositions: result.participantPositions,
        projectLinks: result.projectLinks,
        relatedPeople: result.relatedPeople,
        dictionaryPath: session.dictionaryPath,
        audioFilePath: session.audioFilePath,
        provider: result.provider,
        model: result.model
      )
    )

    try deletePreviousExportIfNeeded(previousPath: session.exportedNotePath, nextPath: notePath.path(percentEncoded: false))

    session.summary = result.summary
    session.organizedTranscript = result.organizedTranscript
    session.keyPoints = result.keyPoints
    session.actionItems = result.actionItems
    session.decisions = result.decisions
    session.openLoops = result.openLoops
    session.risks = result.risks
    session.participantPositions = result.participantPositions
    session.projectLinks = result.projectLinks
    session.relatedPeople = result.relatedPeople
    session.provider = result.provider
    session.model = result.model
    session.exportedNotePath = notePath.path(percentEncoded: false)
    session.status = aiSucceeded ? .exported : .failed
    if aiSucceeded {
      session.errorMessage = nil
    }

    return session
  }

  private func loadDictionary(for session: NativeMeetingSession) async throws -> TermDictionary {
    let url = URL(fileURLWithPath: session.dictionaryPath)
    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      let markdown = try String(contentsOf: url, encoding: .utf8)
      return try TermDictionaryStore.parse(markdown: markdown)
    }

    return try await dictionaryStore.loadDictionary()
  }

  private func fallbackResult(for transcript: String, error: Error) -> DeerAPIResult {
    DeerAPIResult(
      provider: "local",
      model: "postprocess-failed",
      summary: "AI post-processing did not complete. Reason: \(error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines))",
      organizedTranscript: transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No speech was captured in this meeting." : transcript,
      keyPoints: [],
      actionItems: [],
      openLoops: []
    )
  }

  private func deletePreviousExportIfNeeded(previousPath: String?, nextPath: String) throws {
    guard let previousPath, !previousPath.isEmpty, previousPath != nextPath else {
      return
    }

    let previousURL = URL(fileURLWithPath: previousPath)
    if FileManager.default.fileExists(atPath: previousURL.path(percentEncoded: false)) {
      try FileManager.default.removeItem(at: previousURL)
    }
  }
}
