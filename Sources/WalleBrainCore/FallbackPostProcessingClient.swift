import Foundation
import os

public enum PostProcessingLog {
  public typealias Sink = @Sendable (String) -> Void

  private static let logger = Logger(subsystem: "com.wallebrain.app", category: "PostProcessing")

  public static let unifiedLog: Sink = { message in
    logger.notice("\(message, privacy: .public)")
  }

  /// Unified log plus stderr, for command-line tools.
  public static let unifiedLogAndStandardError: Sink = { message in
    logger.notice("\(message, privacy: .public)")
    FileHandle.standardError.write(Data("[post-processing] \(message)\n".utf8))
  }
}

public enum PostProcessingFallbackDecision: Equatable, Sendable {
  /// Propagate the error unchanged (the task was cancelled).
  case propagate
  /// Use the fallback backend for this stage. `disablePrimary` skips the primary for later stages too.
  case fallBack(disablePrimary: Bool)
}

/// Tries a primary backend (Codex CLI) and falls back to a secondary one (OpenAI-compatible API) when the
/// primary is missing, fails, times out, returns unparseable output, or fails transcript quality validation.
/// The fallback client is built lazily, so a missing API configuration never blocks a working primary.
public actor FallbackPostProcessingClient: MeetingPostProcessingClient {
  private let primary: any MeetingPostProcessingClient
  private let primaryName: String
  private let fallbackName: String
  private let makeFallback: @Sendable () throws -> any MeetingPostProcessingClient
  private let log: PostProcessingLog.Sink
  private var fallback: (any MeetingPostProcessingClient)?
  private var primaryDisabledReason: String?

  public init(
    primary: any MeetingPostProcessingClient,
    primaryName: String,
    fallbackName: String,
    makeFallback: @escaping @Sendable () throws -> any MeetingPostProcessingClient,
    log: @escaping PostProcessingLog.Sink = PostProcessingLog.unifiedLog
  ) {
    self.primary = primary
    self.primaryName = primaryName
    self.fallbackName = fallbackName
    self.makeFallback = makeFallback
    self.log = log
  }

  public static func decision(for error: Error, isTaskCancelled: Bool) -> PostProcessingFallbackDecision {
    if isTaskCancelled || error is CancellationError {
      return .propagate
    }
    if let codexError = error as? CodexCLIError {
      return .fallBack(disablePrimary: codexError.isUnavailable)
    }
    return .fallBack(disablePrimary: false)
  }

  public func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult {
    try await run(stage: "organize") {
      try await $0.organizeTranscript(transcript: transcript, dictionary: dictionary)
    } fallback: {
      try await $0.organizeTranscript(transcript: transcript, dictionary: dictionary)
    } describe: {
      "\($0.provider) / \($0.model)"
    }
  }

  public func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult {
    try await run(stage: "analysis") {
      try await $0.analyzeOrganizedTranscript(transcript, preferredModel: preferredModel)
    } fallback: { client in
      var fallbackPreferredModel: String?
      if let preferredModel, await client.acceptsPreferredModel(preferredModel) {
        fallbackPreferredModel = preferredModel
      }
      return try await client.analyzeOrganizedTranscript(transcript, preferredModel: fallbackPreferredModel)
    } describe: {
      "\($0.provider) / \($0.model)"
    }
  }

  public func acceptsPreferredModel(_ model: String) async -> Bool {
    true
  }

  private func run<Result: Sendable>(
    stage: String,
    primary runPrimary: @Sendable (any MeetingPostProcessingClient) async throws -> Result,
    fallback runFallback: @Sendable (any MeetingPostProcessingClient) async throws -> Result,
    describe: (Result) -> String
  ) async throws -> Result {
    let primaryFailure: String
    if let primaryDisabledReason {
      primaryFailure = primaryDisabledReason
      log("\(stage): skipping \(primaryName) (\(primaryDisabledReason)); using \(fallbackName).")
    } else {
      do {
        let result = try await runPrimary(primary)
        log("\(stage): completed with \(describe(result)).")
        return result
      } catch {
        switch Self.decision(for: error, isTaskCancelled: Task.isCancelled) {
        case .propagate:
          throw error
        case let .fallBack(disablePrimary):
          primaryFailure = error.localizedDescription
          if disablePrimary {
            primaryDisabledReason = primaryFailure
          }
          log("\(stage): \(primaryName) failed (\(primaryFailure)); falling back to \(fallbackName).")
        }
      }
    }

    do {
      let client = try fallbackClient()
      let result = try await runFallback(client)
      log("\(stage): completed with \(describe(result)) via fallback.")
      return result
    } catch {
      if Task.isCancelled || error is CancellationError {
        throw error
      }
      log("\(stage): \(fallbackName) fallback failed too (\(error.localizedDescription)).")
      throw WalleBrainError.invalidResponse(
        "\(primaryName) failed: \(primaryFailure) — \(fallbackName) fallback failed: \(error.localizedDescription)"
      )
    }
  }

  private func fallbackClient() throws -> any MeetingPostProcessingClient {
    if let fallback {
      return fallback
    }
    let client = try makeFallback()
    fallback = client
    return client
  }
}

public enum MeetingPostProcessingClientFactory {
  public static let apiBackendName = "OpenAI-compatible API"

  /// Builds the client for the configured backend. `.codex` (the default) is Codex CLI with automatic API
  /// fallback; `.api` is the OpenAI-compatible API only.
  public static func makeClient(
    configuration: ModelConfiguration = ModelConfigurationStore().load(),
    backend: PostProcessingBackend? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    log: @escaping PostProcessingLog.Sink = PostProcessingLog.unifiedLog
  ) throws -> any MeetingPostProcessingClient {
    switch backend ?? configuration.postProcessingBackend {
    case .api:
      log("Post-processing backend: \(apiBackendName).")
      return try LLMChatClient(environment: environment, configuration: configuration)
    case .codex:
      log("Post-processing backend: \(CodexCLIPostProcessingClient.providerLabel), falling back to \(apiBackendName).")
      return FallbackPostProcessingClient(
        primary: CodexCLIPostProcessingClient(
          options: CodexCLIOptions(
            executablePath: configuration.codexExecutablePath,
            model: configuration.codexModel
          ),
          environment: environment
        ),
        primaryName: CodexCLIPostProcessingClient.providerLabel,
        fallbackName: apiBackendName,
        makeFallback: { try LLMChatClient(environment: environment, configuration: configuration) },
        log: log
      )
    }
  }
}
