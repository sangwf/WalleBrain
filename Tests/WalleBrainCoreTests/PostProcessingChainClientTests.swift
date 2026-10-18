import Foundation
import Testing
@testable import WalleBrainCore

struct PostProcessingChainClientTests {
  private let dictionary = TermDictionary(title: "T", entries: [])

  @Test
  func decisionFallsBackForFailuresAndPropagatesCancellation() {
    let missing = LocalCLIError.executableNotFound(tool: "Codex CLI", searched: [], installHint: "")
    let loggedOut = LocalCLIError.notAuthenticated(tool: "Claude Code CLI", details: "Not logged in")
    #expect(PostProcessingChainClient.decision(for: CancellationError(), isTaskCancelled: false) == .propagate)
    #expect(PostProcessingChainClient.decision(for: LocalCLIError.timedOut(seconds: 1), isTaskCancelled: true) == .propagate)
    #expect(PostProcessingChainClient.decision(for: missing, isTaskCancelled: false) == .fallBack(disableTier: true))
    #expect(PostProcessingChainClient.decision(for: loggedOut, isTaskCancelled: false) == .fallBack(disableTier: true))
    #expect(
      PostProcessingChainClient.decision(for: LocalCLIError.timedOut(seconds: 1), isTaskCancelled: false)
        == .fallBack(disableTier: false)
    )
    #expect(
      PostProcessingChainClient.decision(for: WalleBrainError.invalidModelPayload, isTaskCancelled: false)
        == .fallBack(disableTier: false)
    )
  }

  @Test
  func firstTierSuccessNeverBuildsLaterTiers() async throws {
    let codex = ScriptedClient(name: "codex")
    let log = LogRecorder()
    let client = PostProcessingChainClient(
      tiers: [
        tier("Codex CLI", codex),
        PostProcessingChainTier(name: "Claude Code CLI") {
          Issue.record("Later tiers must not be constructed when the first succeeds.")
          return ScriptedClient(name: "claude")
        },
      ],
      log: log.sink
    )

    let organized = try await client.organizeTranscript(transcript: "原文", dictionary: dictionary)
    let analysis = try await client.analyzeOrganizedTranscript(organized.transcript, preferredModel: organized.model)

    #expect(organized.provider == "codex")
    #expect(analysis.provider == "codex")
    #expect(log.messages.contains("organize: completed with codex / codex-model."))
  }

  @Test
  func failingCodexHandsOverToClaudeAndIsRetriedNextStage() async throws {
    let codex = ScriptedClient(name: "codex", organizeError: LocalCLIError.timedOut(seconds: 1800))
    let claude = ScriptedClient(name: "claude")
    let api = ScriptedClient(name: "api")
    let log = LogRecorder()
    let client = PostProcessingChainClient(
      tiers: [tier("Codex CLI", codex), tier("Claude Code CLI", claude), tier("LLM API", api)],
      log: log.sink
    )

    let organized = try await client.organizeTranscript(transcript: "原文", dictionary: dictionary)
    let analysis = try await client.analyzeOrganizedTranscript(organized.transcript, preferredModel: organized.model)

    #expect(organized.provider == "claude")
    #expect(analysis.provider == "codex")
    #expect(await codex.calls == ["organize", "analyze"])
    #expect(await claude.calls == ["organize"])
    #expect(await api.calls.isEmpty)
    #expect(log.messages.contains { $0.contains("Codex CLI failed") && $0.contains("timed out") && $0.contains("trying the next tier") })
    #expect(log.messages.contains { $0.hasPrefix("organize: completed with claude") && $0.contains("after earlier tiers failed") })
  }

  @Test
  func unavailableTiersAreSkippedForLaterStagesAndForeignModelsAreDropped() async throws {
    let codex = ScriptedClient(name: "codex", organizeError: LocalCLIError.executableNotFound(tool: "Codex CLI", searched: [], installHint: ""))
    let claude = ScriptedClient(name: "claude", organizeError: LocalCLIError.notAuthenticated(tool: "Claude Code CLI", details: "Not logged in"))
    let api = ScriptedClient(name: "api", acceptedModels: ["api-pro"])
    let log = LogRecorder()
    let client = PostProcessingChainClient(
      tiers: [tier("Codex CLI", codex), tier("Claude Code CLI", claude), tier("LLM API", api)],
      log: log.sink
    )

    let organized = try await client.organizeTranscript(transcript: "原文", dictionary: dictionary)
    _ = try await client.analyzeOrganizedTranscript("整理稿", preferredModel: "gpt-6-astra")
    _ = try await client.analyzeOrganizedTranscript("整理稿", preferredModel: "api-pro")

    #expect(organized.provider == "api")
    #expect(await codex.calls == ["organize"])
    #expect(await claude.calls == ["organize"])
    #expect(await api.calls == ["organize", "analyze", "analyze"])
    #expect(await api.preferredModels == [nil, "api-pro"])
    #expect(log.messages.contains { $0.hasPrefix("analysis: skipping Codex CLI (unavailable") })
    #expect(log.messages.contains { $0.hasPrefix("analysis: skipping Claude Code CLI (unavailable") })
  }

  @Test
  func reportsEveryTierWhenAllFail() async {
    let client = PostProcessingChainClient(
      tiers: [
        tier("Codex CLI", ScriptedClient(name: "codex", organizeError: LocalCLIError.processFailed(tool: "Codex CLI", exitCode: 1, details: "401"))),
        tier("Claude Code CLI", ScriptedClient(name: "claude", organizeError: LocalCLIError.notAuthenticated(tool: "Claude Code CLI", details: "Not logged in"))),
        PostProcessingChainTier(name: "LLM API") { throw WalleBrainError.invalidResponse("API Key is required.") },
      ],
      log: { _ in }
    )

    do {
      _ = try await client.organizeTranscript(transcript: "原文", dictionary: dictionary)
      Issue.record("Expected every tier to fail.")
    } catch {
      let message = error.localizedDescription
      #expect(message.contains("Codex CLI failed"))
      #expect(message.contains("401"))
      #expect(message.contains("Claude Code CLI failed"))
      #expect(message.contains("Not logged in"))
      #expect(message.contains("LLM API failed"))
      #expect(message.contains("API Key is required."))
    }
  }

  @Test
  func unconstructibleTierIsNotRebuiltForLaterStages() async throws {
    let builds = LogRecorder()
    let codex = ScriptedClient(name: "codex", organizeError: LocalCLIError.timedOut(seconds: 1))
    let client = PostProcessingChainClient(
      tiers: [
        PostProcessingChainTier(name: "LLM API") {
          builds.sink("build")
          throw WalleBrainError.invalidResponse("Base URL is required.")
        },
        tier("Codex CLI", codex),
      ],
      log: { _ in }
    )

    await #expect(throws: WalleBrainError.self) {
      try await client.organizeTranscript(transcript: "原文", dictionary: dictionary)
    }
    _ = try await client.analyzeOrganizedTranscript("整理稿", preferredModel: nil)

    #expect(builds.messages == ["build"])
  }

  @Test
  func cancellationIsNotTreatedAsFallbackTrigger() async {
    let claude = ScriptedClient(name: "claude")
    let client = PostProcessingChainClient(
      tiers: [tier("Codex CLI", ScriptedClient(name: "codex", organizeError: CancellationError())), tier("Claude Code CLI", claude)],
      log: { _ in }
    )

    await #expect(throws: CancellationError.self) {
      try await client.organizeTranscript(transcript: "原文", dictionary: dictionary)
    }
    #expect(await claude.calls.isEmpty)
  }

  @Test
  func factoryBuildsConfiguredOrderAndRejectsEmptyChain() throws {
    let log = LogRecorder()
    let chain = try MeetingPostProcessingClientFactory.makeClient(
      configuration: ModelConfiguration(),
      environment: [:],
      log: log.sink
    )
    #expect(chain is PostProcessingChainClient)
    #expect(log.messages == ["After-meeting processing tiers: Codex CLI → Claude Code CLI → LLM API."])

    let reordered = LogRecorder()
    _ = try MeetingPostProcessingClientFactory.makeClient(
      configuration: ModelConfiguration(postProcessing: PostProcessingConfiguration(tiers: [
        PostProcessingTierSetting(tier: .claudeCode, isEnabled: true),
        PostProcessingTierSetting(tier: .codex, isEnabled: false),
        PostProcessingTierSetting(tier: .api, isEnabled: true),
      ])),
      environment: [:],
      log: reordered.sink
    )
    #expect(reordered.messages == ["After-meeting processing tiers: Claude Code CLI → LLM API."])

    let overridden = LogRecorder()
    _ = try MeetingPostProcessingClientFactory.makeClient(tiers: [.api], environment: [:], log: overridden.sink)
    #expect(overridden.messages == ["After-meeting processing tiers: LLM API."])

    #expect(throws: WalleBrainError.self) {
      try MeetingPostProcessingClientFactory.makeClient(
        configuration: ModelConfiguration(postProcessing: PostProcessingConfiguration(tiers: [
          PostProcessingTierSetting(tier: .codex, isEnabled: false),
        ])),
        environment: [:],
        log: { _ in }
      )
    }
  }

  // MARK: - Settings persistence

  @Test
  func tiersDefaultToCodexClaudeAPIAndRoundTrip() {
    withIsolatedDefaults { defaults in
      let store = ModelConfigurationStore(defaults: defaults)
      #expect(store.load().postProcessing.enabledTiers == [.codex, .claudeCode, .api])

      var configuration = store.load()
      configuration.postProcessing.tiers = [
        PostProcessingTierSetting(tier: .api, isEnabled: true),
        PostProcessingTierSetting(tier: .claudeCode, isEnabled: true),
        PostProcessingTierSetting(tier: .codex, isEnabled: false),
      ]
      configuration.postProcessing.claudeExecutablePath = "/opt/claude/bin/claude"
      configuration.postProcessing.claudeModel = "opus"
      configuration.postProcessing.codexModel = "gpt-test"
      store.save(configuration)

      let loaded = store.load().postProcessing
      #expect(loaded.tiers == configuration.postProcessing.tiers)
      #expect(loaded.enabledTiers == [.api, .claudeCode])
      #expect(loaded.claudeExecutablePath == "/opt/claude/bin/claude")
      #expect(loaded.claudeModel == "opus")
      #expect(loaded.codexModel == "gpt-test")
      #expect(defaults.string(forKey: "WalleBrain.ModelConfiguration.postProcessingBackend") == "codex")
    }
  }

  @Test
  func legacyBackendKeyStaysCompatible() {
    withIsolatedDefaults { defaults in
      defaults.set("api", forKey: "WalleBrain.ModelConfiguration.postProcessingBackend")
      defaults.set("/custom/codex", forKey: "WalleBrain.ModelConfiguration.codexExecutablePath")
      let loaded = ModelConfigurationStore(defaults: defaults).load().postProcessing
      #expect(loaded.enabledTiers == [.api])
      #expect(loaded.tiers.count == 3)
      #expect(loaded.codexExecutablePath == "/custom/codex")

      var apiOnly = ModelConfiguration()
      apiOnly.postProcessing = loaded
      ModelConfigurationStore(defaults: defaults).save(apiOnly)
      #expect(defaults.string(forKey: "WalleBrain.ModelConfiguration.postProcessingBackend") == "api")
    }

    withIsolatedDefaults { defaults in
      defaults.set("codex", forKey: "WalleBrain.ModelConfiguration.postProcessingBackend")
      #expect(ModelConfigurationStore(defaults: defaults).load().postProcessing.enabledTiers == [.codex, .claudeCode, .api])
    }
  }

  @Test
  func tierListNormalizesDuplicatesAndMissingTiers() {
    let configuration = PostProcessingConfiguration(tiers: [
      PostProcessingTierSetting(tier: .api, isEnabled: true),
      PostProcessingTierSetting(tier: .api, isEnabled: false),
    ])
    #expect(configuration.tiers.map(\.tier) == [.api, .codex, .claudeCode])
    #expect(configuration.enabledTiers == [.api])

    #expect(PostProcessingConfiguration.decodeTiers("claudeCode:1,bogus:1,codex:0")?.map(\.tier) == [.claudeCode, .codex])
    #expect(PostProcessingConfiguration.decodeTiers("bogus") == nil)
    #expect(PostProcessingTier(argument: "claude") == .claudeCode)
    #expect(PostProcessingTier(argument: "nope") == nil)
  }

  // MARK: - Helpers

  private func tier(_ name: String, _ client: ScriptedClient) -> PostProcessingChainTier {
    PostProcessingChainTier(name: name) { client }
  }

  private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "WalleBrain.PostProcessingChainClientTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create isolated UserDefaults suite.")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    body(defaults)
  }
}

private actor ScriptedClient: MeetingPostProcessingClient {
  let name: String
  let organizeError: (any Error)?
  let acceptedModels: Set<String>?
  private(set) var calls: [String] = []
  private(set) var preferredModels: [String?] = []

  init(name: String, organizeError: (any Error)? = nil, acceptedModels: Set<String>? = nil) {
    self.name = name
    self.organizeError = organizeError
    self.acceptedModels = acceptedModels
  }

  func organizeTranscript(transcript: String, dictionary: TermDictionary) async throws -> OrganizedTranscriptResult {
    calls.append("organize")
    if let organizeError {
      throw organizeError
    }
    return OrganizedTranscriptResult(provider: name, model: "\(name)-model", transcript: "整理稿")
  }

  func analyzeOrganizedTranscript(_ transcript: String, preferredModel: String?) async throws -> LLMPostProcessingResult {
    calls.append("analyze")
    preferredModels.append(preferredModel)
    return LLMPostProcessingResult(
      provider: name,
      model: preferredModel ?? "\(name)-model",
      summary: "摘要",
      organizedTranscript: transcript,
      keyPoints: [],
      actionItems: []
    )
  }

  func acceptsPreferredModel(_ model: String) async -> Bool {
    acceptedModels?.contains(model) ?? false
  }
}

private final class LogRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var messages: [String] {
    lock.withLock { storage }
  }

  var sink: PostProcessingLog.Sink {
    { [self] message in
      lock.withLock { storage.append(message) }
    }
  }
}
