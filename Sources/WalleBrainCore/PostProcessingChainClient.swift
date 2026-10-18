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
  /// Try the next tier for this stage. `disableTier` also skips the failed tier for later stages.
  case fallBack(disableTier: Bool)
}

public struct PostProcessingChainTier: Sendable {
  public let name: String
  /// Built lazily on first use, so a misconfigured later tier never blocks a working earlier one.
  public let makeClient: @Sendable () throws -> any MeetingPostProcessingClient

  public init(name: String, makeClient: @escaping @Sendable () throws -> any MeetingPostProcessingClient) {
    self.name = name
    self.makeClient = makeClient
  }
}

/// Runs each post-processing stage on the first tier that succeeds, in order (by default Codex CLI → Claude Code
/// CLI → OpenAI-compatible API). A tier is skipped when it fails, times out, returns unparseable output, or fails
/// transcript quality validation; a tier that cannot run at all (missing binary, not logged in, unconfigured) is
/// also skipped for the remaining stages.
public actor PostProcessingChainClient: MeetingPostProcessingClient {
  private let tiers: [PostProcessingChainTier]
  private let log: PostProcessingLog.Sink
  private var clients: [Int: any MeetingPostProcessingClient] = [:]
  private var disabledReasons: [Int: String] = [:]

  public init(
    tiers: [PostProcessingChainTier],
    log: @escaping PostProcessingLog.Sink = PostProcessingLog.unifiedLog
  ) {
    self.tiers = tiers
    self.log = log
  }

  public static func decision(for error: Error, isTaskCancelled: Bool) -> PostProcessingFallbackDecision {
    if isTaskCancelled || error is CancellationError {
      return .propagate
    }
    if let cliError = error as? LocalCLIError {
      return .fallBack(disableTier: cliError.isUnavailable)
    }
    return .fallBack(disableTier: false)
  }

  public func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult {
    try await run(stage: "organize") {
      try await $0.organizeTranscript(transcript: transcript, dictionary: dictionary)
    } describe: {
      "\($0.provider) / \($0.model)"
    }
  }

  /// Each tier receives `preferredModel` only if it recognises it, so one backend's model name never reaches
  /// another backend.
  public func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult {
    try await run(stage: "analysis") { client in
      var tierPreferredModel: String?
      if let preferredModel, await client.acceptsPreferredModel(preferredModel) {
        tierPreferredModel = preferredModel
      }
      return try await client.analyzeOrganizedTranscript(transcript, preferredModel: tierPreferredModel)
    } describe: {
      "\($0.provider) / \($0.model)"
    }
  }

  public func acceptsPreferredModel(_ model: String) async -> Bool {
    true
  }

  private func run<Result: Sendable>(
    stage: String,
    operation: @Sendable (any MeetingPostProcessingClient) async throws -> Result,
    describe: (Result) -> String
  ) async throws -> Result {
    guard !tiers.isEmpty else {
      throw WalleBrainError.invalidResponse("No after-meeting processing tier is enabled.")
    }

    var failures: [String] = []
    for (index, tier) in tiers.enumerated() {
      let hasNextTier = index < tiers.count - 1
      if let reason = disabledReasons[index] {
        failures.append("\(tier.name) skipped: \(reason)")
        log("\(stage): skipping \(tier.name) (unavailable: \(reason)).")
        continue
      }

      do {
        let client = try client(at: index)
        let result = try await operation(client)
        let fallbackNote = failures.isEmpty ? "" : " after earlier tiers failed [\(failures.joined(separator: " — "))]"
        log("\(stage): completed with \(describe(result))\(fallbackNote).")
        return result
      } catch {
        switch Self.decision(for: error, isTaskCancelled: Task.isCancelled) {
        case .propagate:
          throw error
        case let .fallBack(disableTier):
          let reason = error.localizedDescription
          let tierWasNeverBuilt = clients[index] == nil
          if disableTier || tierWasNeverBuilt {
            disabledReasons[index] = reason
          }
          failures.append("\(tier.name) failed: \(reason)")
          log("\(stage): \(tier.name) failed (\(reason))\(hasNextTier ? "; trying the next tier" : "").")
        }
      }
    }

    throw WalleBrainError.invalidResponse("All after-meeting processing tiers failed. \(failures.joined(separator: " — "))")
  }

  private func client(at index: Int) throws -> any MeetingPostProcessingClient {
    if let client = clients[index] {
      return client
    }
    let client = try tiers[index].makeClient()
    clients[index] = client
    return client
  }
}

public enum MeetingPostProcessingClientFactory {
  /// Builds the configured chain of enabled tiers (default Codex CLI → Claude Code CLI → OpenAI-compatible API).
  /// `tiers` overrides the configured order, e.g. for command-line tools.
  public static func makeClient(
    configuration: ModelConfiguration = ModelConfigurationStore().load(),
    tiers: [PostProcessingTier]? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    log: @escaping PostProcessingLog.Sink = PostProcessingLog.unifiedLog
  ) throws -> any MeetingPostProcessingClient {
    let postProcessing = configuration.postProcessing
    let order = tiers ?? postProcessing.enabledTiers
    guard !order.isEmpty else {
      throw WalleBrainError.invalidResponse("No after-meeting processing tier is enabled. Enable one in Settings.")
    }
    log("After-meeting processing tiers: \(order.map(\.displayName).joined(separator: " → ")).")

    let chainTiers = order.map { tier -> PostProcessingChainTier in
      switch tier {
      case .codex:
        return PostProcessingChainTier(name: tier.displayName) {
          CodexCLIPostProcessingClient(
            options: LocalCLIOptions(executablePath: postProcessing.codexExecutablePath, model: postProcessing.codexModel),
            environment: environment
          )
        }
      case .claudeCode:
        return PostProcessingChainTier(name: tier.displayName) {
          ClaudeCodeCLIPostProcessingClient(
            options: LocalCLIOptions(executablePath: postProcessing.claudeExecutablePath, model: postProcessing.claudeModel),
            environment: environment
          )
        }
      case .api:
        return PostProcessingChainTier(name: tier.displayName) {
          try LLMChatClient(environment: environment, configuration: configuration)
        }
      }
    }
    return PostProcessingChainClient(tiers: chainTiers, log: log)
  }
}
