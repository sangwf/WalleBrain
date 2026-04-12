import Foundation

public struct TranscriptCorrectionEngine: Sendable {
  public init() {}

  public func apply(
    to transcript: String,
    sessionCorrections: [TranscriptCorrection],
    memoryEntries: [CorrectionMemoryEntry]
  ) -> String {
    var replacementsByWrong: [String: TranscriptCorrection] = [:]

    for entry in memoryEntries {
      let wrong = entry.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
      let correct = entry.correct.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !wrong.isEmpty, !correct.isEmpty, wrong != correct else {
        continue
      }
      replacementsByWrong[wrong] = TranscriptCorrection(wrong: wrong, correct: correct, type: entry.type)
    }

    for correction in sessionCorrections {
      let wrong = correction.wrong.trimmingCharacters(in: .whitespacesAndNewlines)
      let correct = correction.correct.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !wrong.isEmpty, !correct.isEmpty, wrong != correct else {
        continue
      }
      replacementsByWrong[wrong] = TranscriptCorrection(id: correction.id, wrong: wrong, correct: correct, type: correction.type)
    }

    let replacements = replacementsByWrong.values.sorted {
      if $0.wrong.count == $1.wrong.count {
        return $0.wrong < $1.wrong
      }
      return $0.wrong.count > $1.wrong.count
    }

    guard !replacements.isEmpty else {
      return transcript
    }

    var corrected = transcript
    var tokenMap: [String: String] = [:]

    for (index, replacement) in replacements.enumerated() {
      let token = "__WALLEBRAIN_CORRECTION_\(index)__"
      corrected = corrected.replacingOccurrences(of: replacement.wrong, with: token)
      tokenMap[token] = replacement.correct
    }

    for (token, value) in tokenMap {
      corrected = corrected.replacingOccurrences(of: token, with: value)
    }

    return corrected
  }
}
