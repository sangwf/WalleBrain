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

    ## Action Items
    \(render(items: note.actionItems))

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

  private static func sanitize(_ title: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    return title
      .components(separatedBy: invalid)
      .joined(separator: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
