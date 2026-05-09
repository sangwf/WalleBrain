import Foundation

public struct RealtimeTranscriptionConfiguration: Sendable, Hashable {
  public static let apiKeyEnvironmentVariable = "OPENAI_API_KEY"
  public static let modelEnvironmentVariable = "WALLEBRAIN_REALTIME_TRANSCRIPTION_MODEL"
  public static let defaultModel = "gpt-realtime-whisper"
  public static let defaultProvider = "OpenAI Realtime"

  public let apiKey: String
  public let model: String
  public let provider: String

  public init(
    apiKey: String,
    model: String = RealtimeTranscriptionConfiguration.defaultModel,
    provider: String = RealtimeTranscriptionConfiguration.defaultProvider
  ) {
    self.apiKey = apiKey
    self.model = model
    self.provider = provider
  }
}

public struct RealtimeTranscriptionConfigurationPreview: Sendable, Hashable {
  public let apiKey: ResolvedConfigurationValue
  public let model: String
  public let provider: String

  public var isValid: Bool {
    apiKey.isValid && !model.isEmpty && !provider.isEmpty
  }
}

public struct RealtimeTranscriptionConfigurationResolver: Sendable {
  private let mergedEnvironment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.mergedEnvironment = ShellEnvironmentLoader.mergedEnvironment(from: environment)
  }

  init(mergedEnvironment: [String: String]) {
    self.mergedEnvironment = mergedEnvironment
  }

  public func preview() -> RealtimeTranscriptionConfigurationPreview {
    RealtimeTranscriptionConfigurationPreview(
      apiKey: resolveAPIKey(),
      model: resolvedModel(),
      provider: RealtimeTranscriptionConfiguration.defaultProvider
    )
  }

  public func resolve() throws -> RealtimeTranscriptionConfiguration {
    let preview = preview()
    if let errorMessage = preview.apiKey.errorMessage {
      throw WalleBrainError.invalidResponse(errorMessage)
    }
    guard let apiKey = preview.apiKey.resolvedValue, !apiKey.isEmpty else {
      throw WalleBrainError.invalidResponse("Environment variable \(RealtimeTranscriptionConfiguration.apiKeyEnvironmentVariable) is not set.")
    }

    return RealtimeTranscriptionConfiguration(
      apiKey: apiKey,
      model: preview.model,
      provider: preview.provider
    )
  }

  private func resolveAPIKey() -> ResolvedConfigurationValue {
    let variableName = RealtimeTranscriptionConfiguration.apiKeyEnvironmentVariable
    if let value = mergedEnvironment[variableName], !value.isEmpty {
      return ResolvedConfigurationValue(
        rawValue: "$\(variableName)",
        resolvedValue: value,
        sourceDescription: "Environment: \(variableName)",
        errorMessage: nil
      )
    }

    return ResolvedConfigurationValue(
      rawValue: "$\(variableName)",
      resolvedValue: nil,
      sourceDescription: "Environment: \(variableName)",
      errorMessage: "Environment variable \(variableName) is not set."
    )
  }

  private func resolvedModel() -> String {
    let value = mergedEnvironment[RealtimeTranscriptionConfiguration.modelEnvironmentVariable]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value! : RealtimeTranscriptionConfiguration.defaultModel
  }
}
