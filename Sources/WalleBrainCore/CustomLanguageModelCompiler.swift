import Foundation
import Speech

public actor CustomLanguageModelCompiler {
  private let paths: RuntimePaths

  public init(paths: RuntimePaths) {
    self.paths = paths
  }

  public func compile(dictionary: TermDictionary, locale: Locale = Locale(identifier: "zh_CN")) async throws -> CompiledLanguageAssets {
    try paths.ensureDirectories()

    let identifier = "com.wallebrain.dictionary"
    let version = Self.versionStamp(for: dictionary)
    let assetURL = paths.speechAssetsDirectory.appending(path: "\(identifier).asset", directoryHint: .notDirectory)
    let languageModelURL = paths.speechAssetsDirectory.appending(path: "\(identifier).lm", directoryHint: .notDirectory)
    let vocabularyURL = paths.speechAssetsDirectory.appending(path: "\(identifier).vocab", directoryHint: .notDirectory)

    let data = SFCustomLanguageModelData(locale: locale, identifier: identifier, version: version)
    for entry in dictionary.entries {
      data.insert(phraseCount: .init(phrase: entry.canonical, count: 64))
      for alias in entry.aliases where !alias.isEmpty {
        data.insert(phraseCount: .init(phrase: alias, count: 24))
      }
    }

    try await data.export(to: assetURL)

    let configuration = SFSpeechLanguageModel.Configuration(
      languageModel: languageModelURL,
      vocabulary: vocabularyURL,
      weight: NSNumber(value: 0.72)
    )

    try await prepareCustomLanguageModel(assetURL: assetURL, configuration: configuration)

    return CompiledLanguageAssets(
      assetDataURL: assetURL,
      languageModelURL: languageModelURL,
      vocabularyURL: vocabularyURL
    )
  }

  public func configuration(for assets: CompiledLanguageAssets) -> SFSpeechLanguageModel.Configuration {
    SFSpeechLanguageModel.Configuration(
      languageModel: assets.languageModelURL,
      vocabulary: assets.vocabularyURL,
      weight: NSNumber(value: 0.72)
    )
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

  private static func versionStamp(for dictionary: TermDictionary) -> String {
    let payload = dictionary.entries
      .map { "\($0.canonical)|\($0.aliases.joined(separator: ","))|\($0.type ?? "")|\($0.notes ?? "")" }
      .joined(separator: "\n")
    return String(payload.hashValue.magnitude)
  }
}
