import Foundation

public struct ModelConfiguration: Codable, Sendable, Hashable {
  public static let defaultBaseURLReference = "$WALLEBRAIN_LLM_BASE_URL"
  public static let defaultAPIKeyReference = "$WALLEBRAIN_LLM_API_KEY"
  public static let defaultModelsReference = "$WALLEBRAIN_LLM_MODELS"
  public static let defaultProviderLabelReference = "OpenAI-compatible"
  public static let legacyDefaultModelsChainReference = "gemini-3-flash-preview, gemini-3.1-pro-preview"
  public static let legacyDefaultModelsReference = "gemini-3.1-pro-preview"

  public var baseURLReference: String
  public var apiKeyReference: String
  public var modelsReference: String
  public var providerLabelReference: String

  public init(
    baseURLReference: String = ModelConfiguration.defaultBaseURLReference,
    apiKeyReference: String = ModelConfiguration.defaultAPIKeyReference,
    modelsReference: String = ModelConfiguration.defaultModelsReference,
    providerLabelReference: String = ModelConfiguration.defaultProviderLabelReference
  ) {
    self.baseURLReference = baseURLReference
    self.apiKeyReference = apiKeyReference
    self.modelsReference = modelsReference
    self.providerLabelReference = providerLabelReference
  }
}

public struct ResolvedConfigurationValue: Sendable, Hashable {
  public let rawValue: String
  public let resolvedValue: String?
  public let sourceDescription: String
  public let errorMessage: String?

  public var isValid: Bool {
    errorMessage == nil && resolvedValue?.isEmpty == false
  }
}

public struct ResolvedModelConfigurationPreview: Sendable, Hashable {
  public let baseURL: ResolvedConfigurationValue
  public let apiKey: ResolvedConfigurationValue
  public let models: ResolvedConfigurationValue
  public let providerLabel: ResolvedConfigurationValue
  public let resolvedModels: [String]

  public var isValid: Bool {
    baseURL.isValid && apiKey.isValid && models.isValid && providerLabel.isValid && !resolvedModels.isEmpty
  }
}

public struct ResolvedModelConfiguration: Sendable, Hashable {
  public let baseURL: String
  public let apiKey: String
  public let models: [String]
  public let providerLabel: String
}

public struct ModelConfigurationStore {
  private enum Keys {
    static let baseURLReference = "WalleBrain.ModelConfiguration.baseURLReference"
    static let apiKeyReference = "WalleBrain.ModelConfiguration.apiKeyReference"
    static let modelReference = "WalleBrain.ModelConfiguration.modelReference"
    static let modelsReference = "WalleBrain.ModelConfiguration.modelsReference"
    static let providerLabelReference = "WalleBrain.ModelConfiguration.providerLabelReference"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> ModelConfiguration {
    let storedModelsReference = defaults.string(forKey: Keys.modelsReference)
      ?? defaults.string(forKey: Keys.modelReference)
    let effectiveModelsReference: String
    if let storedModelsReference {
      let normalized = storedModelsReference.trimmingCharacters(in: .whitespacesAndNewlines)
      effectiveModelsReference = normalized == ModelConfiguration.legacyDefaultModelsReference
        || normalized == ModelConfiguration.legacyDefaultModelsChainReference
        ? ModelConfiguration.defaultModelsReference
        : storedModelsReference
    } else {
      effectiveModelsReference = ModelConfiguration.defaultModelsReference
    }

    return ModelConfiguration(
      baseURLReference: defaults.string(forKey: Keys.baseURLReference) ?? ModelConfiguration.defaultBaseURLReference,
      apiKeyReference: defaults.string(forKey: Keys.apiKeyReference) ?? ModelConfiguration.defaultAPIKeyReference,
      modelsReference: effectiveModelsReference,
      providerLabelReference: defaults.string(forKey: Keys.providerLabelReference) ?? ModelConfiguration.defaultProviderLabelReference
    )
  }

  public func save(_ configuration: ModelConfiguration) {
    defaults.set(configuration.baseURLReference, forKey: Keys.baseURLReference)
    defaults.set(configuration.apiKeyReference, forKey: Keys.apiKeyReference)
    defaults.set(configuration.modelsReference, forKey: Keys.modelsReference)
    defaults.set(configuration.providerLabelReference, forKey: Keys.providerLabelReference)
  }
}

public struct ModelConfigurationResolver: Sendable {
  private let mergedEnvironment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.mergedEnvironment = ShellEnvironmentLoader.mergedEnvironment(from: environment)
  }

  init(mergedEnvironment: [String: String]) {
    self.mergedEnvironment = mergedEnvironment
  }

  public func preview(for configuration: ModelConfiguration) -> ResolvedModelConfigurationPreview {
    let models = resolveField(configuration.modelsReference, label: "Models")
    return ResolvedModelConfigurationPreview(
      baseURL: resolveField(configuration.baseURLReference, label: "Base URL"),
      apiKey: resolveField(configuration.apiKeyReference, label: "API Key"),
      models: models,
      providerLabel: resolveField(configuration.providerLabelReference, label: "Provider Label"),
      resolvedModels: parseModels(from: models.resolvedValue)
    )
  }

  public func resolve(_ configuration: ModelConfiguration) throws -> ResolvedModelConfiguration {
    let preview = preview(for: configuration)

    if let errorMessage = preview.baseURL.errorMessage {
      throw WalleBrainError.invalidResponse(errorMessage)
    }
    if let errorMessage = preview.apiKey.errorMessage {
      throw WalleBrainError.invalidResponse(errorMessage)
    }
    if let errorMessage = preview.models.errorMessage {
      throw WalleBrainError.invalidResponse(errorMessage)
    }
    if let errorMessage = preview.providerLabel.errorMessage {
      throw WalleBrainError.invalidResponse(errorMessage)
    }

    guard let baseURL = preview.baseURL.resolvedValue, URL(string: baseURL) != nil else {
      throw WalleBrainError.invalidResponse("Resolved Base URL is invalid.")
    }
    guard let apiKey = preview.apiKey.resolvedValue, !apiKey.isEmpty else {
      throw WalleBrainError.invalidResponse("Resolved API Key is empty.")
    }
    guard !preview.resolvedModels.isEmpty else {
      throw WalleBrainError.invalidResponse("Resolved models list is empty.")
    }
    guard let providerLabel = preview.providerLabel.resolvedValue, !providerLabel.isEmpty else {
      throw WalleBrainError.invalidResponse("Resolved Provider Label is empty.")
    }

    return ResolvedModelConfiguration(
      baseURL: baseURL,
      apiKey: apiKey,
      models: preview.resolvedModels,
      providerLabel: providerLabel
    )
  }

  private func parseModels(from resolvedValue: String?) -> [String] {
    guard let resolvedValue else {
      return []
    }

    var seen: Set<String> = []
    var models: [String] = []

    for candidate in resolvedValue.split(separator: ",") {
      let model = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty, seen.insert(model).inserted else {
        continue
      }
      models.append(model)
    }

    return models
  }

  private func resolveField(_ rawValue: String, label: String) -> ResolvedConfigurationValue {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !trimmed.isEmpty else {
      return ResolvedConfigurationValue(
        rawValue: rawValue,
        resolvedValue: nil,
        sourceDescription: "Missing",
        errorMessage: "\(label) is required."
      )
    }

    guard trimmed.hasPrefix("$") else {
      return ResolvedConfigurationValue(
        rawValue: rawValue,
        resolvedValue: trimmed,
        sourceDescription: "Literal value",
        errorMessage: nil
      )
    }

    let variableName = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !variableName.isEmpty else {
      return ResolvedConfigurationValue(
        rawValue: rawValue,
        resolvedValue: nil,
        sourceDescription: "Environment variable",
        errorMessage: "\(label) references an empty environment variable name."
      )
    }

    if let value = mergedEnvironment[variableName], !value.isEmpty {
      return ResolvedConfigurationValue(
        rawValue: rawValue,
        resolvedValue: value,
        sourceDescription: "Environment: \(variableName)",
        errorMessage: nil
      )
    }

    if let fallback = legacyFallback(for: variableName) {
      return fallbackValue(for: fallback, rawValue: rawValue, primaryVariableName: variableName, label: label)
    }

    return ResolvedConfigurationValue(
      rawValue: rawValue,
      resolvedValue: nil,
      sourceDescription: "Environment: \(variableName)",
      errorMessage: "Environment variable \(variableName) is not set."
    )
  }

  private func legacyFallback(for variableName: String) -> [String]? {
    switch variableName {
    case "WALLEBRAIN_LLM_BASE_URL":
      return ["OPENAI_BASE_URL", "DEERAPI_BASE_URL"]
    case "WALLEBRAIN_LLM_API_KEY":
      return ["DEERAPI_KEY", "OPENAI_API_KEY"]
    case "WALLEBRAIN_LLM_MODELS":
      return ["WALLEBRAIN_MODELS", "OPENAI_MODEL"]
    default:
      return nil
    }
  }

  private func fallbackValue(
    for variableNames: [String],
    rawValue: String,
    primaryVariableName: String,
    label: String
  ) -> ResolvedConfigurationValue {
    for variableName in variableNames {
      if let value = mergedEnvironment[variableName], !value.isEmpty {
        return ResolvedConfigurationValue(
          rawValue: rawValue,
          resolvedValue: value,
          sourceDescription: "Environment: \(variableName) fallback for \(primaryVariableName)",
          errorMessage: nil
        )
      }
    }

    return ResolvedConfigurationValue(
      rawValue: rawValue,
      resolvedValue: nil,
      sourceDescription: "Environment: \(primaryVariableName)",
      errorMessage: "Environment variable \(primaryVariableName) is not set."
    )
  }
}
