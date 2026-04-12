import Foundation

public actor CorrectionMemoryStore {
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

  public func load() throws -> [CorrectionMemoryEntry] {
    try paths.ensureDirectories()

    let url = paths.correctionMemoryFile
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return []
    }

    let data = try Data(contentsOf: url)
    return try decoder.decode([CorrectionMemoryEntry].self, from: data)
  }

  public func save(_ entries: [CorrectionMemoryEntry]) throws {
    try paths.ensureDirectories()
    let data = try encoder.encode(entries)
    try data.write(to: paths.correctionMemoryFile, options: .atomic)
  }

  public func merge(_ corrections: [TranscriptCorrection]) throws {
    let normalizedCorrections = corrections.compactMap(Self.normalize)
    guard !normalizedCorrections.isEmpty else {
      return
    }

    var entries = try load()
    let now = Date()

    for correction in normalizedCorrections {
      if let existingIndex = entries.firstIndex(where: { Self.key(forWrong: $0.wrong, correct: $0.correct) == Self.key(forWrong: correction.wrong, correct: correction.correct) }) {
        entries[existingIndex].count += 1
        entries[existingIndex].updatedAt = now
        if entries[existingIndex].type == nil {
          entries[existingIndex].type = correction.type
        }
      } else {
        entries.append(
          CorrectionMemoryEntry(
            wrong: correction.wrong,
            correct: correction.correct,
            type: correction.type,
            count: 1,
            updatedAt: now
          )
        )
      }
    }

    entries.sort { left, right in
      if left.updatedAt == right.updatedAt {
        return left.wrong < right.wrong
      }
      return left.updatedAt > right.updatedAt
    }

    try save(entries)
  }

  private static func normalize(_ correction: TranscriptCorrection) -> TranscriptCorrection? {
    let wrong = correction.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
    let correct = correction.correct.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !wrong.isEmpty, !correct.isEmpty, wrong != correct else {
      return nil
    }

    return TranscriptCorrection(id: correction.id, wrong: wrong, correct: correct, type: correction.type)
  }

  private static func key(forWrong wrong: String, correct: String) -> String {
    "\(wrong.lowercased())::\(correct.lowercased())"
  }
}
