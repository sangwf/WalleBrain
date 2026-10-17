import Foundation

public enum TranscriptionEvaluationMetrics {
  public static func normalizeTextForComparison(_ input: String) -> String {
    let compatible = input.precomposedStringWithCompatibilityMapping.lowercased()
    let removedScalars = CharacterSet.whitespacesAndNewlines
      .union(.punctuationCharacters)
      .union(.symbols)

    let scalars = compatible.unicodeScalars.filter { scalar in
      !removedScalars.contains(scalar)
    }
    return String(String.UnicodeScalarView(scalars))
  }

  public static func characterErrorRate(expected: String, actual: String) -> Double {
    let normalizedExpected = normalizeTextForComparison(expected)
    let normalizedActual = normalizeTextForComparison(actual)

    guard !normalizedExpected.isEmpty else {
      return normalizedActual.isEmpty ? 0 : 1
    }

    let distance = levenshteinDistance(
      Array(normalizedExpected),
      Array(normalizedActual)
    )
    return min(1, Double(distance) / Double(normalizedExpected.count))
  }

  public static func characterAccuracy(expected: String, actual: String) -> Double {
    max(0, 1 - characterErrorRate(expected: expected, actual: actual))
  }

  public static func isNormalizedExactMatch(expected: String, actual: String) -> Bool {
    normalizeTextForComparison(expected) == normalizeTextForComparison(actual)
  }

  /// Dictionary-term mentions in the reference, and how many of them the hypothesis reproduced
  /// (per term, capped at the reference count so extra insertions do not inflate recall).
  public static func termMentionCounts(
    expected: String,
    actual: String,
    terms: [String]
  ) -> (expected: Int, matched: Int) {
    let normalizedExpected = normalizeTextForComparison(expected)
    let normalizedActual = normalizeTextForComparison(actual)
    var expectedCount = 0
    var matchedCount = 0
    var seen = Set<String>()

    // Longer terms first, consuming their spans, so `张俊峰` is not also counted as `俊峰`.
    var remainingExpected = normalizedExpected
    var remainingActual = normalizedActual
    for term in terms.map(normalizeTextForComparison).sorted(by: { $0.count > $1.count }) {
      guard !term.isEmpty, seen.insert(term).inserted else {
        continue
      }
      let inExpected = occurrences(of: term, in: remainingExpected)
      let inActual = occurrences(of: term, in: remainingActual)
      expectedCount += inExpected
      matchedCount += min(inExpected, inActual)
      remainingExpected = remainingExpected.replacingOccurrences(of: term, with: "\u{0}")
      remainingActual = remainingActual.replacingOccurrences(of: term, with: "\u{0}")
    }
    return (expectedCount, matchedCount)
  }

  private static func occurrences(of term: String, in text: String) -> Int {
    text.components(separatedBy: term).count - 1
  }

  private static func levenshteinDistance(_ left: [Character], _ right: [Character]) -> Int {
    if left == right {
      return 0
    }

    if left.isEmpty {
      return right.count
    }

    if right.isEmpty {
      return left.count
    }

    var previous = Array(0...right.count)
    var current = Array(repeating: 0, count: right.count + 1)

    for row in 1...left.count {
      current[0] = row

      for column in 1...right.count {
        let substitutionCost = left[row - 1] == right[column - 1] ? 0 : 1
        current[column] = min(
          current[column - 1] + 1,
          previous[column] + 1,
          previous[column - 1] + substitutionCost
        )
      }

      previous = current
    }

    return previous[right.count]
  }
}
