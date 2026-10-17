import Foundation

public actor TermDictionaryStore {
  private let paths: RuntimePaths

  public init(paths: RuntimePaths) {
    self.paths = paths
  }

  public func ensureExists() throws -> URL {
    try paths.ensureDirectories()

    if !FileManager.default.fileExists(atPath: paths.dictionaryFile.path(percentEncoded: false)) {
      try Self.sampleMarkdown.write(to: paths.dictionaryFile, atomically: true, encoding: .utf8)
    }

    return paths.dictionaryFile
  }

  public func loadRawMarkdown() throws -> String {
    _ = try ensureExists()
    return try String(contentsOf: paths.dictionaryFile, encoding: .utf8)
  }

  public func saveRawMarkdown(_ markdown: String) throws {
    _ = try ensureExists()
    try markdown.write(to: paths.dictionaryFile, atomically: true, encoding: .utf8)
  }

  public func loadDictionary() throws -> TermDictionary {
    try Self.parse(markdown: loadRawMarkdown())
  }

  /// Parses the Business Dictionary markdown. Every `##` (or deeper) heading starts its own entry; a
  /// deeper heading such as `### 张俊峰` under `## 神策` records the enclosing heading in its notes.
  /// Keys accept `:` or `：`, and aliases split on `,`, `，` or `、`.
  public static func parse(markdown: String) throws -> TermDictionary {
    let lines = markdown.components(separatedBy: .newlines)
    var title = "Business Dictionary"
    var entries: [TermEntry] = []

    var canonical: String?
    var parent: String?
    var aliases: [String] = []
    var type: String?
    var notes: String?
    var headingStack: [(level: Int, text: String)] = []

    func flushCurrentEntry() {
      guard let canonical, !canonical.isEmpty else {
        return
      }

      let parentNote = parent.map { "parent: \($0)" }
      entries.append(
        TermEntry(
          canonical: canonical,
          aliases: aliases.filter { !$0.isEmpty },
          type: type?.nilIfEmpty,
          notes: [notes?.nilIfEmpty, parentNote].compactMap { $0 }.joined(separator: "; ").nilIfEmpty
        )
      )
    }

    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespaces)

      if line.hasPrefix("# "), entries.isEmpty {
        title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        continue
      }

      if let heading = entryHeading(line) {
        flushCurrentEntry()
        headingStack.removeAll { $0.level >= heading.level }
        canonical = heading.text
        parent = headingStack.last?.text.nilIfEmpty
        headingStack.append(heading)
        aliases = []
        type = nil
        notes = nil
        continue
      }

      guard line.hasPrefix("- "), canonical != nil else {
        if !line.isEmpty, canonical != nil {
          notes = [notes, line].compactMap { $0 }.joined(separator: " ")
        }
        continue
      }

      let payload = line.dropFirst(2)
      guard let separator = payload.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
        continue
      }

      let key = payload[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = payload[payload.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

      switch key {
      case "aliases":
        aliases = value
          .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      case "type":
        type = value
      case "notes":
        notes = value
      default:
        notes = [notes, "\(key): \(value)"].compactMap { $0 }.joined(separator: " ")
      }
    }

    flushCurrentEntry()

    if entries.isEmpty {
      throw WalleBrainError.dictionaryMissingEntry("No `## term` sections were found.")
    }

    return TermDictionary(title: title, entries: entries)
  }

  /// `## term`, `### term`, ... — any heading of level two or deeper.
  private static func entryHeading(_ line: String) -> (level: Int, text: String)? {
    let level = line.prefix { $0 == "#" }.count
    guard level >= 2, line.dropFirst(level).first == " " else {
      return nil
    }
    return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
  }

  public static let sampleMarkdown = """
  # Business Dictionary

  ## WalleBrain
  - aliases: wall brain
  - type: product
  - notes: Native macOS meeting assistant

  ## LLM
  - aliases: deer api
  - type: service
  - notes: Model gateway used for post-processing

  ## CRM
  - aliases: c r m
  - type: business
  - notes: Customer relationship management system
  """
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
