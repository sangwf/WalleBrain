import Foundation

public struct OrganizedTranscriptQualityReport: Sendable, Hashable {
  public let lengthRatio: Double
  public let sourceChineseRatio: Double
  public let organizedChineseRatio: Double
  public let maximumRepeatedSentenceCount: Int

  public init(
    lengthRatio: Double,
    sourceChineseRatio: Double,
    organizedChineseRatio: Double,
    maximumRepeatedSentenceCount: Int
  ) {
    self.lengthRatio = lengthRatio
    self.sourceChineseRatio = sourceChineseRatio
    self.organizedChineseRatio = organizedChineseRatio
    self.maximumRepeatedSentenceCount = maximumRepeatedSentenceCount
  }
}

public enum OrganizedTranscriptQualityValidator {
  private static let deliberationMarkers = [
    "let's search memory",
    "what about \"",
    "no, wait.",
    "wait, \"",
    "as an ai language model",
    "i need to identify",
    "i should search",
  ]

  @discardableResult
  public static func validate(
    organizedTranscript: String,
    sourceTranscript: String
  ) throws -> OrganizedTranscriptQualityReport {
    let organized = organizedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = sourceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !source.isEmpty else {
      throw WalleBrainError.invalidResponse("Cannot validate against an empty source transcript.")
    }
    guard !organized.isEmpty else {
      throw WalleBrainError.invalidResponse("Organized transcript is empty.")
    }

    let lengthRatio = Double(organized.count) / Double(max(source.count, 1))
    let minimumLengthRatio = source.count >= 500 ? 0.35 : 0.15
    guard lengthRatio >= minimumLengthRatio, lengthRatio <= 1.5 else {
      throw WalleBrainError.invalidResponse(
        "Organized transcript length ratio \(String(format: "%.2f", lengthRatio)) is outside the safe range."
      )
    }

    let lowercased = organized.lowercased()
    guard !deliberationMarkers.contains(where: lowercased.contains) else {
      throw WalleBrainError.invalidResponse("Organized transcript contains model deliberation.")
    }

    let sourceChineseRatio = chineseCharacterRatio(in: source)
    let organizedChineseRatio = chineseCharacterRatio(in: organized)
    if sourceChineseRatio >= 0.35 {
      let minimumChineseRatio = max(0.35, sourceChineseRatio * 0.6)
      guard organizedChineseRatio >= minimumChineseRatio else {
        throw WalleBrainError.invalidResponse(
          "Organized transcript Chinese ratio \(String(format: "%.2f", organizedChineseRatio)) is too low."
        )
      }
    }

    let maximumRepeatedSentenceCount = repeatedSentenceMaximum(in: organized)
    guard maximumRepeatedSentenceCount < 3 else {
      throw WalleBrainError.invalidResponse(
        "Organized transcript contains a long sentence repeated \(maximumRepeatedSentenceCount) times."
      )
    }

    return OrganizedTranscriptQualityReport(
      lengthRatio: lengthRatio,
      sourceChineseRatio: sourceChineseRatio,
      organizedChineseRatio: organizedChineseRatio,
      maximumRepeatedSentenceCount: maximumRepeatedSentenceCount
    )
  }

  private static func chineseCharacterRatio(in text: String) -> Double {
    let characters = text.filter { !$0.isWhitespace }
    let chineseCount = characters.reduce(into: 0) { count, character in
      guard let scalar = character.unicodeScalars.first else {
        return
      }
      if (0x3400 ... 0x9FFF).contains(Int(scalar.value)) {
        count += 1
      }
    }
    return Double(chineseCount) / Double(max(characters.count, 1))
  }

  private static func repeatedSentenceMaximum(in text: String) -> Int {
    let separators = CharacterSet(charactersIn: "。！？!?；;\n")
    let sentences = text
      .components(separatedBy: separators)
      .map {
        $0.lowercased()
          .components(separatedBy: .whitespacesAndNewlines)
          .filter { !$0.isEmpty }
          .joined(separator: " ")
      }
      .filter { $0.count >= 30 }

    var counts: [String: Int] = [:]
    for sentence in sentences {
      counts[sentence, default: 0] += 1
    }
    return counts.values.max() ?? 0
  }
}
