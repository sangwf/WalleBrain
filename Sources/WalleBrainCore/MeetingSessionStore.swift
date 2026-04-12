import Foundation

public actor MeetingSessionStore {
  private let paths: RuntimePaths
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(paths: RuntimePaths) {
    self.paths = paths
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder.dateEncodingStrategy = .iso8601
    self.decoder = JSONDecoder()
    self.decoder.dateDecodingStrategy = .iso8601
  }

  public func createSession(
    title: String,
    mode: MeetingMode,
    dictionaryPath: String,
    selectedInput: AudioInputDevice?,
    startedAt: Date = Date()
  ) throws -> NativeMeetingSession {
    try paths.ensureDirectories()

    let fileStem = Self.fileStem(for: title, startedAt: startedAt)
    let audioFilePath = if let selectedInput, AudioInputCatalog.isManualInput(id: selectedInput.id) {
      ""
    } else {
      paths.audioRecordingURL(fileStem: fileStem).path(percentEncoded: false)
    }
    let session = NativeMeetingSession(
      title: title,
      mode: mode,
      status: .preparing,
      startedAt: startedAt,
      selectedInput: selectedInput,
      dictionaryPath: dictionaryPath,
      audioFilePath: audioFilePath,
      sessionJSONPath: paths.sessionJSONURL(fileStem: fileStem).path(percentEncoded: false),
      sessionMarkdownPath: paths.sessionMarkdownURL(fileStem: fileStem).path(percentEncoded: false)
    )

    try save(session)
    return session
  }

  public func save(_ session: NativeMeetingSession) throws {
    try paths.ensureDirectories()

    let jsonURL = URL(fileURLWithPath: session.sessionJSONPath)
    let markdownURL = URL(fileURLWithPath: session.sessionMarkdownPath)
    let jsonData = try encoder.encode(session)

    try jsonData.write(to: jsonURL, options: .atomic)
    try renderMarkdown(for: session).write(to: markdownURL, atomically: true, encoding: .utf8)
  }

  public func delete(_ session: NativeMeetingSession) throws {
    try deleteFileIfExists(at: session.sessionJSONPath)
    try deleteFileIfExists(at: session.sessionMarkdownPath)
    try deleteFileIfExists(at: session.audioFilePath)

    if let exportedNotePath = session.exportedNotePath, !exportedNotePath.isEmpty {
      try deleteFileIfExists(at: exportedNotePath)
    }
  }

  public func listSessions(limit: Int? = nil) throws -> [NativeMeetingSession] {
    try paths.ensureDirectories()

    let files = try FileManager.default.contentsOfDirectory(
      at: paths.nativeMeetingSessionsDirectory,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
      .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasSuffix(".session.json") }

    var sessions: [NativeMeetingSession] = []
    sessions.reserveCapacity(files.count)

    for url in files {
      do {
        let data = try Data(contentsOf: url)
        let session = try decoder.decode(NativeMeetingSession.self, from: data)
        sessions.append(session)
      } catch {
        continue
      }
    }

    sessions.sort { left, right in
      if left.startedAt == right.startedAt {
        return left.id.uuidString > right.id.uuidString
      }
      return left.startedAt > right.startedAt
    }

    if let limit, sessions.count > limit {
      return Array(sessions.prefix(limit))
    }

    return sessions
  }

  private func renderMarkdown(for session: NativeMeetingSession) -> String {
    let iso = ISO8601DateFormatter()
    let ended = session.endedAt.map { iso.string(from: $0) } ?? ""
    let transcript = session.liveTranscript.isEmpty ? "_No transcript yet._" : session.liveTranscript
    let correctedTranscript = session.correctedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? session.correctedTranscript!
      : "_Pending_"
    let organizedTranscript = session.organizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? session.organizedTranscript!
      : "_Pending_"
    let keyPoints = session.keyPoints.isEmpty ? "- None" : session.keyPoints.map { "- \($0)" }.joined(separator: "\n")
    let actionItems = session.actionItems.isEmpty ? "- None" : session.actionItems.map { "- \($0)" }.joined(separator: "\n")
    let decisions = (session.decisions ?? []).isEmpty
      ? "- None"
      : (session.decisions ?? []).map {
        let project = $0.relatedProjectID.map { " [project: \($0)]" } ?? ""
        return "- \($0.text) [\($0.status.rawValue)]\(project)"
      }.joined(separator: "\n")
    let openLoops = (session.openLoops ?? []).isEmpty
      ? "- None"
      : (session.openLoops ?? []).map {
        let owner = $0.owner.map { " owner=\($0)" } ?? ""
        let dueHint = $0.dueHint.map { " due=\($0)" } ?? ""
        return "- [\($0.type.rawValue)] \($0.text)\(owner)\(dueHint)"
      }.joined(separator: "\n")
    let risks = (session.risks ?? []).isEmpty
      ? "- None"
      : (session.risks ?? []).map {
        let project = $0.relatedProjectID.map { " [project: \($0)]" } ?? ""
        return "- \($0.text)\(project)"
      }.joined(separator: "\n")
    let projectLinks = (session.projectLinks ?? []).isEmpty
      ? "- None"
      : (session.projectLinks ?? []).map {
        "- \($0.project.title) [\($0.role.rawValue), \($0.status.rawValue), confidence=\(String(format: "%.2f", $0.confidence))]"
      }.joined(separator: "\n")
    let relatedPeople = (session.relatedPeople ?? []).isEmpty
      ? "- None"
      : (session.relatedPeople ?? []).map { "- \($0.displayName)" }.joined(separator: "\n")
    let participantPositions = (session.participantPositions ?? []).isEmpty
      ? "- None"
      : (session.participantPositions ?? []).map {
        let label = $0.person?.displayName ?? $0.label
        return "- \(label): \($0.stance)"
      }.joined(separator: "\n")
    let reviewComments = (session.reviewComments ?? []).isEmpty
      ? "- None"
      : (session.reviewComments ?? []).map {
        let proposed = $0.proposedText.map { " -> \($0)" } ?? ""
        return "- [\($0.type.rawValue)] \($0.comment)\(proposed)"
      }.joined(separator: "\n")
    let corrections = (session.sessionCorrections ?? []).isEmpty
      ? "- None"
      : (session.sessionCorrections ?? []).map {
        let type = $0.type?.isEmpty == false ? " [\($0.type!)]" : ""
        return "- \($0.wrong) -> \($0.correct)\(type)"
      }.joined(separator: "\n")

    return """
    ---
    type: meeting-session
    title: \(session.title)
    status: \(session.status.rawValue)
    mode: \(session.mode.rawValue)
    started_at: \(iso.string(from: session.startedAt))
    ended_at: \(ended)
    audio_file: \(session.audioFilePath)
    dictionary_file: \(session.dictionaryPath)
    input_device: \(session.selectedInput?.name ?? "")
    exported_note: \(session.exportedNotePath ?? "")
    ---

    # \(session.title)

    ## Live Transcript
    \(transcript)

    ## Corrected Transcript
    \(correctedTranscript)

    ## Summary
    \(session.summary ?? "_Pending_")

    ## Organized Transcript
    \(organizedTranscript)

    ## Key Points
    \(keyPoints)

    ## Decisions
    \(decisions)

    ## Action Items
    \(actionItems)

    ## Open Loops
    \(openLoops)

    ## Risks
    \(risks)

    ## Related Projects
    \(projectLinks)

    ## Related People
    \(relatedPeople)

    ## Participant Positions
    \(participantPositions)

    ## Corrections
    \(corrections)

    ## Review Comments
    \(reviewComments)

    ## Error
    \(session.errorMessage ?? "_None_")
    """
  }

  private static func fileStem(for title: String, startedAt: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    let timestamp = formatter.string(from: startedAt)
    let sanitized = title
      .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sanitized.isEmpty ? timestamp : "\(timestamp) \(sanitized)"
  }

  private func deleteFileIfExists(at path: String) throws {
    guard !path.isEmpty else {
      return
    }

    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
