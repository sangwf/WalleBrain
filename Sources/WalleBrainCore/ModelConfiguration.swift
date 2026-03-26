import Foundation

public struct ModelConfiguration: Codable, Sendable, Hashable {
  public var baseURLReference: String
  public var apiKeyReference: String
  public var modelsReference: String

  public init(
    baseURLReference: String = "$DEERAPI_BASE_URL",
    apiKeyReference: String = "$DEERAPI_KEY",
    modelsReference: String = "gemini-3-flash-preview"
  ) {
    self.baseURLReference = baseURLReference
    self.apiKeyReference = apiKeyReference
    self.modelsReference = modelsReference
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
  public let resolvedModels: [String]

  public var isValid: Bool {
    baseURL.isValid && apiKey.isValid && models.isValid && !resolvedModels.isEmpty
  }
}

public struct ResolvedModelConfiguration: Sendable, Hashable {
  public let baseURL: String
  public let apiKey: String
  public let models: [String]
}

public struct ModelConfigurationStore {
  private enum Keys {
    static let baseURLReference = "WalleBrain.ModelConfiguration.baseURLReference"
    static let apiKeyReference = "WalleBrain.ModelConfiguration.apiKeyReference"
    static let modelReference = "WalleBrain.ModelConfiguration.modelReference"
    static let modelsReference = "WalleBrain.ModelConfiguration.modelsReference"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> ModelConfiguration {
    ModelConfiguration(
      baseURLReference: defaults.string(forKey: Keys.baseURLReference) ?? "$DEERAPI_BASE_URL",
      apiKeyReference: defaults.string(forKey: Keys.apiKeyReference) ?? "$DEERAPI_KEY",
      modelsReference: defaults.string(forKey: Keys.modelsReference)
        ?? defaults.string(forKey: Keys.modelReference)
        ?? "gemini-3-flash-preview"
    )
  }

  public func save(_ configuration: ModelConfiguration) {
    defaults.set(configuration.baseURLReference, forKey: Keys.baseURLReference)
    defaults.set(configuration.apiKeyReference, forKey: Keys.apiKeyReference)
    defaults.set(configuration.modelsReference, forKey: Keys.modelsReference)
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

    guard let baseURL = preview.baseURL.resolvedValue, URL(string: baseURL) != nil else {
      throw WalleBrainError.invalidResponse("Resolved Base URL is invalid.")
    }
    guard let apiKey = preview.apiKey.resolvedValue, !apiKey.isEmpty else {
      throw WalleBrainError.invalidResponse("Resolved API Key is empty.")
    }
    guard !preview.resolvedModels.isEmpty else {
      throw WalleBrainError.invalidResponse("Resolved models list is empty.")
    }

    return ResolvedModelConfiguration(
      baseURL: baseURL,
      apiKey: apiKey,
      models: preview.resolvedModels
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

    guard let value = mergedEnvironment[variableName], !value.isEmpty else {
      return ResolvedConfigurationValue(
        rawValue: rawValue,
        resolvedValue: nil,
        sourceDescription: "Environment: \(variableName)",
        errorMessage: "Environment variable \(variableName) is not set."
      )
    }

    return ResolvedConfigurationValue(
      rawValue: rawValue,
      resolvedValue: value,
      sourceDescription: "Environment: \(variableName)",
      errorMessage: nil
    )
  }
}
