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

  public static func parse(markdown: String) throws -> TermDictionary {
    let lines = markdown.components(separatedBy: .newlines)
    var title = "Business Dictionary"
    var entries: [TermEntry] = []

    var canonical: String?
    var aliases: [String] = []
    var type: String?
    var notes: String?

    func flushCurrentEntry() {
      guard let canonical, !canonical.isEmpty else {
        return
      }

      entries.append(
        TermEntry(
          canonical: canonical,
          aliases: aliases.filter { !$0.isEmpty },
          type: type?.nilIfEmpty,
          notes: notes?.nilIfEmpty
        )
      )
    }

    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespaces)

      if line.hasPrefix("# "), entries.isEmpty {
        title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        continue
      }

      if line.hasPrefix("## ") {
        flushCurrentEntry()
        canonical = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
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

      let payload = String(line.dropFirst(2))
      let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else {
        continue
      }

      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

      switch key {
      case "aliases":
        aliases = value
          .replacingOccurrences(of: "，", with: ",")
          .split(separator: ",")
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

  public static let sampleMarkdown = """
  # Business Dictionary

  ## WalleBrain
  - aliases: wall brain
  - type: product
  - notes: Native macOS meeting assistant

  ## DeerAPI
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
