import CryptoKit
import Foundation

/// Converts the Business Dictionary into the vocabulary inputs used to bias live speech recognition.
public enum SpeechVocabulary {
  public struct WeightedPhrase: Sendable, Hashable {
    public let phrase: String
    public let count: Int

    public init(phrase: String, count: Int) {
      self.phrase = phrase
      self.count = count
    }
  }

  /// Bump when the phrase weighting or asset layout changes so cached language models are rebuilt.
  public static let compilerFormatVersion = 2
  public static let canonicalPhraseCount = 64
  public static let aliasPhraseCount = 24
  public static let defaultContextualStringLimit = 100

  /// Canonical terms first (they matter most), then aliases; trimmed and de-duplicated case-insensitively.
  public static func contextualStrings(
    from dictionary: TermDictionary,
    limit: Int = defaultContextualStringLimit
  ) -> [String] {
    let canonicals = dictionary.entries.map(\.canonical)
    let aliases = dictionary.entries.flatMap(\.aliases)
    return Array(uniquePhrases(canonicals + aliases).prefix(max(0, limit)))
  }

  public static func weightedPhrases(from dictionary: TermDictionary) -> [WeightedPhrase] {
    var seen = Set<String>()
    var phrases: [WeightedPhrase] = []

    func append(_ raw: String, count: Int) {
      let phrase = normalizedPhrase(raw)
      guard !phrase.isEmpty, seen.insert(phrase.lowercased()).inserted else {
        return
      }
      phrases.append(WeightedPhrase(phrase: phrase, count: count))
    }

    for entry in dictionary.entries {
      append(entry.canonical, count: canonicalPhraseCount)
    }
    for entry in dictionary.entries {
      for alias in entry.aliases {
        append(alias, count: aliasPhraseCount)
      }
    }
    return phrases
  }

  /// Stable across processes and launches (unlike `hashValue`). Only inputs that change the compiled
  /// model participate, so editing a term's notes or type does not force a recompile.
  public static func cacheKey(for dictionary: TermDictionary, localeIdentifier: String) -> String {
    let payload = (
      ["v\(compilerFormatVersion)", normalizedLocaleIdentifier(localeIdentifier)]
        + weightedPhrases(from: dictionary).map { "\($0.phrase)\t\($0.count)" }
    ).joined(separator: "\n")
    let digest = SHA256.hash(data: Data(payload.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  public static func normalizedLocaleIdentifier(_ identifier: String) -> String {
    identifier.replacingOccurrences(of: "-", with: "_")
  }

  private static func uniquePhrases(_ rawPhrases: [String]) -> [String] {
    var seen = Set<String>()
    return rawPhrases
      .map(normalizedPhrase)
      .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
  }

  private static func normalizedPhrase(_ raw: String) -> String {
    raw
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

/// Dictionary-derived inputs for one live local-speech session.
public struct LiveSpeechVocabulary: Sendable {
  public let dictionary: TermDictionary
  public let contextualStrings: [String]
  public let termRepair: PhoneticTermRepair

  public init(dictionary: TermDictionary) {
    self.dictionary = dictionary
    contextualStrings = SpeechVocabulary.contextualStrings(from: dictionary)
    termRepair = PhoneticTermRepair(dictionary: dictionary)
  }

  public static let empty = LiveSpeechVocabulary(dictionary: TermDictionary(title: "", entries: []))
}
