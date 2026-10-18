import Foundation

/// Repairs near-homophone misrecognitions of Chinese dictionary terms in live ASR output
/// (e.g. `神车` / `神者` / `神特` → `神策`).
///
/// Apple's `SpeechTranscriber` exposes no vocabulary-biasing hook (contextual strings are ignored and custom
/// language models only attach to `DictationTranscriber`), so this deterministic pass is what keeps
/// dictionary terms right while recording. It is deliberately conservative: a span is only rewritten when
/// it has the same length as the term, every differing syllable is a near-homophone (only its initial
/// or its final may differ), at least one character is
/// already identical, and the span sits on word boundaries without being a real word itself (so `精神车间`,
/// `政策` and `家乡` are left alone).
public struct PhoneticTermRepair: Sendable {
  struct Syllable: Sendable, Hashable {
    let initial: String
    let final: String
  }

  struct Target: Sendable {
    let phrase: String
    let characters: [Character]
    let syllables: [Syllable]
  }

  public struct Replacement: Sendable, Hashable {
    public let original: String
    public let replacement: String
  }

  let targets: [Target]

  public init(phrases: [String]) {
    var seen = Set<String>()
    targets = phrases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { phrase in
        (2...8).contains(phrase.count)
          && phrase.allSatisfy(Self.isHan)
          && seen.insert(phrase).inserted
      }
      .compactMap { phrase in
        let characters = Array(phrase)
        let syllables = characters.compactMap(Self.syllable(for:))
        guard syllables.count == characters.count else {
          return nil
        }
        return Target(phrase: phrase, characters: characters, syllables: syllables)
      }
      // Longer terms first so a long name wins over a shorter alias inside it.
      .sorted { $0.characters.count > $1.characters.count }
  }

  public init(dictionary: TermDictionary) {
    self.init(phrases: SpeechVocabulary.contextualStrings(from: dictionary, limit: .max))
  }

  public var targetCount: Int {
    targets.count
  }

  public func apply(to text: String) -> String {
    repair(text).text
  }

  public func repair(_ text: String) -> (text: String, replacements: [Replacement]) {
    guard !targets.isEmpty, text.contains(where: Self.isHan) else {
      return (text, [])
    }

    var characters = Array(text)
    let segmentation = Self.segment(text)
    var replacements: [Replacement] = []
    var protected = Array(repeating: false, count: characters.count)

    for target in targets {
      let length = target.characters.count
      guard characters.count >= length else {
        continue
      }

      var start = 0
      while start + length <= characters.count {
        let end = start + length
        let window = characters[start..<end]
        if protected[start..<end].contains(true) {
          start += 1
          continue
        }
        if window.elementsEqual(target.characters) {
          protected.replaceSubrange(start..<end, with: repeatElement(true, count: length))
          start = end
          continue
        }
        if segmentation.boundaries.contains(start),
           segmentation.boundaries.contains(end),
           !segmentation.words.contains(WordSpan(start: start, end: end)),
           matches(Array(window), target: target) {
          replacements.append(Replacement(original: String(window), replacement: target.phrase))
          characters.replaceSubrange(start..<end, with: target.characters)
          protected.replaceSubrange(start..<end, with: repeatElement(true, count: length))
          start = end
          continue
        }
        start += 1
      }
    }

    return (String(characters), replacements)
  }

  private func matches(_ window: [Character], target: Target) -> Bool {
    var identical = 0
    var differing = 0
    for (index, character) in window.enumerated() {
      if character == target.characters[index] {
        identical += 1
        continue
      }
      guard let syllable = Self.syllable(for: character),
            Self.isNearHomophone(syllable, target.syllables[index]) else {
        return false
      }
      differing += 1
    }
    // At least one anchor character, and never rewrite more than a third of a longer term.
    return identical >= 1 && differing >= 1 && differing <= max(1, window.count / 3)
  }

  // MARK: - Pinyin

  private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]

  /// Initials that Apple Speech routinely confuses in fast Mandarin (dental/retroflex sibilants and `t`,
  /// plus the common regional n/l and f/h mergers).
  private static let initialGroups: [Set<String>] = [
    ["z", "c", "s", "zh", "ch", "sh", "t"],
    ["n", "l"],
    ["f", "h"],
  ]

  private static let finalGroups: [Set<String>] = [
    ["en", "eng"],
    ["in", "ing"],
    ["an", "ang"],
  ]

  static func syllable(for character: Character) -> Syllable? {
    guard isHan(character),
          let latin = String(character).applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased()
            .trimmingCharacters(in: .whitespaces),
          !latin.isEmpty,
          latin.allSatisfy({ $0.isASCII && $0.isLetter })
    else {
      return nil
    }

    let initial = initials.first { latin.hasPrefix($0) && latin.count > $0.count } ?? ""
    return Syllable(initial: initial, final: String(latin.dropFirst(initial.count)))
  }

  /// Only one of initial/final may be fuzzy, so real words like `政策` (zheng vs shen) are not pulled to `神策`.
  static func isNearHomophone(_ lhs: Syllable, _ rhs: Syllable) -> Bool {
    if lhs.initial == rhs.initial {
      return lhs.final == rhs.final
        || finalGroups.contains { $0.contains(lhs.final) && $0.contains(rhs.final) }
    }
    return lhs.final == rhs.final
      && initialGroups.contains { $0.contains(lhs.initial) && $0.contains(rhs.initial) }
  }

  static func isHan(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy { scalar in
      (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }
  }

  struct WordSpan: Hashable {
    let start: Int
    let end: Int
  }

  /// Character offsets where words start or end (a candidate span must not cut through a real word), plus
  /// the spans the tokenizer recognises as whole words. Misrecognitions like `神车` split into `神|车`, while
  /// real words like `政策`, `家乡` or `神色` stay whole and are never rewritten.
  static func segment(_ text: String) -> (boundaries: Set<Int>, words: Set<WordSpan>) {
    var boundaries: Set<Int> = [0, text.count]
    var words = Set<WordSpan>()
    let range = CFRange(location: 0, length: (text as NSString).length)
    let tokenizer = CFStringTokenizerCreate(
      nil,
      text as CFString,
      range,
      kCFStringTokenizerUnitWordBoundary,
      Locale(identifier: "zh_CN") as CFLocale
    )

    var utf16Tokens: [(start: Int, end: Int)] = []
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
      let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      utf16Tokens.append((tokenRange.location, tokenRange.location + tokenRange.length))
    }

    var characterOffsetByUTF16Offset: [Int: Int] = [:]
    var characterOffset = 0
    var utf16Offset = 0
    for character in text {
      characterOffsetByUTF16Offset[utf16Offset] = characterOffset
      characterOffset += 1
      utf16Offset += character.utf16.count
    }
    characterOffsetByUTF16Offset[utf16Offset] = characterOffset

    for token in utf16Tokens {
      guard let start = characterOffsetByUTF16Offset[token.start],
            let end = characterOffsetByUTF16Offset[token.end] else {
        continue
      }
      boundaries.insert(start)
      boundaries.insert(end)
      words.insert(WordSpan(start: start, end: end))
    }
    return (boundaries, words)
  }
}
