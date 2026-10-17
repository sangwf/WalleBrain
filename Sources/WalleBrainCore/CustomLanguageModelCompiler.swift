import Foundation
import Speech

/// Builds an `SFSpeechLanguageModel` from the Business Dictionary.
///
/// On macOS 26 the compiled model can only be attached to `DictationTranscriber`
/// (`ContentHint.customizedLanguage`); `SpeechTranscriber`, which the live path uses, has no such hook.
/// Compiled assets are cached by dictionary content, so unchanged dictionaries are never recompiled.
public actor CustomLanguageModelCompiler {
  public static let languageModelWeight = 0.72

  private let paths: RuntimePaths

  public init(paths: RuntimePaths) {
    self.paths = paths
  }

  public func compile(dictionary: TermDictionary, locale: Locale = Locale(identifier: "zh_CN")) async throws -> CompiledLanguageAssets {
    try paths.ensureDirectories()

    let identifier = Self.identifier(for: locale)
    let version = SpeechVocabulary.cacheKey(for: dictionary, localeIdentifier: locale.identifier)
    let assets = assets(identifier: identifier, version: version)

    if Self.isCompiled(assets) {
      pruneStaleAssets(identifier: identifier, keeping: version)
      return assets
    }

    let data = SFCustomLanguageModelData(locale: locale, identifier: identifier, version: version)
    for phrase in SpeechVocabulary.weightedPhrases(from: dictionary) {
      data.insert(phraseCount: .init(phrase: phrase.phrase, count: phrase.count))
    }

    do {
      try await data.export(to: assets.assetDataURL)
      try await prepareCustomLanguageModel(assetURL: assets.assetDataURL, configuration: configuration(for: assets))
    } catch {
      // Never leave half-written files that a later run would mistake for a cache hit.
      Self.remove(assets)
      throw error
    }

    pruneStaleAssets(identifier: identifier, keeping: version)
    return assets
  }

  public func configuration(for assets: CompiledLanguageAssets) -> SFSpeechLanguageModel.Configuration {
    SFSpeechLanguageModel.Configuration(
      languageModel: assets.languageModelURL,
      vocabulary: assets.vocabularyURL,
      weight: NSNumber(value: Self.languageModelWeight)
    )
  }

  static func identifier(for locale: Locale) -> String {
    "com.wallebrain.dictionary.\(SpeechVocabulary.normalizedLocaleIdentifier(locale.identifier))"
  }

  private func assets(identifier: String, version: String) -> CompiledLanguageAssets {
    let stem = "\(identifier).\(version)"
    return CompiledLanguageAssets(
      assetDataURL: paths.speechAssetsDirectory.appending(path: "\(stem).asset", directoryHint: .notDirectory),
      languageModelURL: paths.speechAssetsDirectory.appending(path: "\(stem).lm", directoryHint: .notDirectory),
      vocabularyURL: paths.speechAssetsDirectory.appending(path: "\(stem).vocab", directoryHint: .notDirectory)
    )
  }

  private static func isCompiled(_ assets: CompiledLanguageAssets) -> Bool {
    [assets.assetDataURL, assets.languageModelURL, assets.vocabularyURL].allSatisfy { url in
      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return size > 0
    }
  }

  private static func remove(_ assets: CompiledLanguageAssets) {
    for url in [assets.assetDataURL, assets.languageModelURL, assets.vocabularyURL] {
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Older builds of the same locale's model are several MB each and are never read again.
  private func pruneStaleAssets(identifier: String, keeping version: String) {
    let directory = paths.speechAssetsDirectory
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
      return
    }

    let prefix = "\(identifier)."
    let current = "\(identifier).\(version)."
    for name in names where name.hasPrefix(prefix) && !name.hasPrefix(current) {
      try? FileManager.default.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
    }
  }

  private func prepareCustomLanguageModel(
    assetURL: URL,
    configuration: SFSpeechLanguageModel.Configuration,
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      SFSpeechLanguageModel.prepareCustomLanguageModel(for: assetURL, configuration: configuration) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: ())
        }
      }
    }
  }
}
