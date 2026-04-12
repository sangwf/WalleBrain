import Foundation

public actor NoteExporter {
  private let paths: RuntimePaths

  public init(paths: RuntimePaths) {
    self.paths = paths
  }

  public func export(note: NativeMeetingNote) throws -> URL {
    try paths.ensureDirectories()

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
    let timestamp = formatter.string(from: note.startedAt)
    let sanitizedTitle = Self.sanitize(note.title)
    let fileStem = sanitizedTitle.isEmpty ? timestamp : "\(timestamp) \(sanitizedTitle)"
    let target = paths.obsidianMeetingsDirectory.appending(path: "\(fileStem).md", directoryHint: .notDirectory)

    let markdown = """
    ---
    type: meeting
    title: \(note.title)
    date: \(ISO8601DateFormatter().string(from: note.startedAt))
    provider: \(note.provider)
    model: \(note.model)
    dictionary_file: \(note.dictionaryPath)
    audio_file: \(note.audioFilePath)
    ---

    # \(note.title)

    ## Summary
    \(note.summary)

    ## Organized Transcript
    \(note.organizedTranscript)

    ## Key Points
    \(render(items: note.keyPoints))

    ## Decisions
    \(render(decisions: note.decisions))

    ## Action Items
    \(render(items: note.actionItems))

    ## Open Loops
    \(render(openLoops: note.openLoops))

    ## Risks
    \(render(risks: note.risks))

    ## Related Projects
    \(render(projectLinks: note.projectLinks))

    ## Related People
    \(render(people: note.relatedPeople))

    ## Participant Positions
    \(render(positions: note.participantPositions))

    ## Live Transcript
    \(note.liveTranscript)

    ## Final Transcript
    \(note.transcript)
    """

    try markdown.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  private func render(items: [String]) -> String {
    if items.isEmpty {
      return "- None"
    }

    return items.map { "- \($0)" }.joined(separator: "\n")
  }

  private func render(decisions: [MeetingDecision]) -> String {
    if decisions.isEmpty {
      return "- None"
    }

    return decisions.map { decision in
      let status = decision.status.rawValue
      let project = decision.relatedProjectID.map { " [project: \($0)]" } ?? ""
      return "- \(decision.text) [\(status)]\(project)"
    }.joined(separator: "\n")
  }

  private func render(openLoops: [MeetingOpenLoop]) -> String {
    if openLoops.isEmpty {
      return "- None"
    }

    return openLoops.map { loop in
      let owner = loop.owner.map { " owner=\($0)" } ?? ""
      let dueHint = loop.dueHint.map { " due=\($0)" } ?? ""
      return "- [\(loop.type.rawValue)] \(loop.text)\(owner)\(dueHint)"
    }.joined(separator: "\n")
  }

  private func render(risks: [MeetingRisk]) -> String {
    if risks.isEmpty {
      return "- None"
    }

    return risks.map { risk in
      let project = risk.relatedProjectID.map { " [project: \($0)]" } ?? ""
      return "- \(risk.text)\(project)"
    }.joined(separator: "\n")
  }

  private func render(projectLinks: [MeetingProjectLink]) -> String {
    if projectLinks.isEmpty {
      return "- None"
    }

    return projectLinks.map { link in
      "- \(link.project.title) [\(link.role.rawValue), \(link.status.rawValue), confidence=\(String(format: "%.2f", link.confidence))]"
    }.joined(separator: "\n")
  }

  private func render(people: [PersonReference]) -> String {
    if people.isEmpty {
      return "- None"
    }

    return people.map { "- \($0.displayName)" }.joined(separator: "\n")
  }

  private func render(positions: [ParticipantPosition]) -> String {
    if positions.isEmpty {
      return "- None"
    }

    return positions.map { position in
      let label = position.person?.displayName ?? position.label
      return "- \(label): \(position.stance)"
    }.joined(separator: "\n")
  }

  private static func sanitize(_ title: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    return title
      .components(separatedBy: invalid)
      .joined(separator: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
