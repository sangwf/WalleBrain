import Foundation
import Testing
@testable import WalleBrainCore

struct FallbackPostProcessingClientTests {
  @Test
  func decisionFallsBackForFailuresAndPropagatesCancellation() {
    #expect(FallbackPostProcessingClient.decision(for: CancellationError(), isTaskCancelled: false) == .propagate)
    #expect(FallbackPostProcessingClient.decision(for: CodexCLIError.timedOut(seconds: 1), isTaskCancelled: true) == .propagate)
    #expect(
      FallbackPostProcessingClient.decision(for: CodexCLIError.executableNotFound(searched: []), isTaskCancelled: false)
        == .fallBack(disablePrimary: true)
    )
    #expect(
      FallbackPostProcessingClient.decision(for: CodexCLIError.executableUnusable(details: []), isTaskCancelled: false)
        == .fallBack(disablePrimary: true)
    )
    #expect(
      FallbackPostProcessingClient.decision(for: CodexCLIError.timedOut(seconds: 1), isTaskCancelled: false)
        == .fallBack(disablePrimary: false)
    )
    #expect(
      FallbackPostProcessingClient.decision(for: WalleBrainError.invalidModelPayload, isTaskCancelled: false)
        == .fallBack(disablePrimary: false)
    )
  }

  @Test
  func primarySuccessNeverBuildsFallback() async throws {
    let primary = ScriptedClient(name: "codex")
    let log = LogRecorder()
    let client = FallbackPostProcessingClient(
      primary: primary,
      primaryName: "Codex CLI",
      fallbackName: "API",
      makeFallback: {
        Issue.record("Fallback must not be constructed when the primary succeeds.")
        return ScriptedClient(name: "api")
      },
      log: log.sink
    )

    let organized = try await client.organizeTranscript(transcript: "原文", dictionary: TermDictionary(title: "T", entries: []))
    let analysis = try await client.analyzeOrganizedTranscript(organized.transcript, preferredModel: organized.model)

    #expect(organized.provider == "codex")
    #expect(analysis.provider == "codex")
    #expect(log.messages.contains { $0.contains("organize: completed with codex") })
  }

  @Test
  func processFailureFallsBackPerStageAndRetriesPrimaryLater() async throws {
    let primary = ScriptedClient(name: "codex", organizeError: CodexCLIError.timedOut(seconds: 1800))
    let fallback = ScriptedClient(name: "api", acceptedModels: ["api-pro"])
    let log = LogRecorder()
    let client = FallbackPostProcessingClient(
      primary: primary,
      primaryName: "Codex CLI",
      fallbackName: "API",
      makeFallback: { fallback },
      log: log.sink
    )

    let organized = try await client.organizeTranscript(transcript: "原文", dictionary: TermDictionary(title: "T", entries: []))
    let analysis = try await client.analyzeOrganizedTranscript(organized.transcript, preferredModel: organized.model)

    #expect(organized.provider == "api")
    #expect(analysis.provider == "codex")
    #expect(await primary.calls == ["organize", "analyze"])
    #expect(await fallback.calls == ["organize"])
    #expect(log.messages.contains { $0.contains("Codex CLI failed") && $0.contains("timed out") })
  }

  @Test
  func unavailablePrimaryIsSkippedForLaterStagesAndForeignModelIsDropped() async throws {
    let primary = ScriptedClient(name: "codex", organizeError: CodexCLIError.executableNotFound(searched: ["/opt/homebrew/bin/codex"]))
    let fallback = ScriptedClient(name: "api", acceptedModels: ["api-pro"])
    let client = FallbackPostProcessingClient(
      primary: primary,
      primaryName: "Codex CLI",
      fallbackName: "API",
      makeFallback: { fallback },
      log: { _ in }
    )

    _ = try await client.organizeTranscript(transcript: "原文", dictionary: TermDictionary(title: "T", entries: []))
    _ = try await client.analyzeOrganizedTranscript("整理稿", preferredModel: "gpt-6-astra")
    _ = try await client.analyzeOrganizedTranscript("整理稿", preferredModel: "api-pro")

    #expect(await primary.calls == ["organize"])
    #expect(await fallback.calls == ["organize", "analyze", "analyze"])
    #expect(await fallback.preferredModels == [nil, "api-pro"])
  }

  @Test
  func reportsBothFailuresWhenFallbackAlsoFails() async {
    let client = FallbackPostProcessingClient(
      primary: ScriptedClient(name: "codex", organizeError: CodexCLIError.processFailed(exitCode: 1, details: "401")),
      primaryName: "Codex CLI",
      fallbackName: "API",
      makeFallback: { throw WalleBrainError.invalidResponse("API Key is required.") },
      log: { _ in }
    )

    do {
      _ = try await client.organizeTranscript(transcript: "原文", dictionary: TermDictionary(title: "T", entries: []))
      Issue.record("Expected both backends to fail.")
    } catch {
      #expect(error.localizedDescription.contains("Codex CLI failed"))
      #expect(error.localizedDescription.contains("401"))
      #expect(error.localizedDescription.contains("API Key is required."))
    }
  }

  @Test
  func cancellationIsNotTreatedAsFallbackTrigger() async {
    let fallback = ScriptedClient(name: "api")
    let client = FallbackPostProcessingClient(
      primary: ScriptedClient(name: "codex", organizeError: CancellationError()),
      primaryName: "Codex CLI",
      fallbackName: "API",
      makeFallback: { fallback },
      log: { _ in }
    )

    await #expect(throws: CancellationError.self) {
      try await client.organizeTranscript(transcript: "原文", dictionary: TermDictionary(title: "T", entries: []))
    }
    #expect(await fallback.calls.isEmpty)
  }

  @Test
  func factoryDefaultsToCodexWithFallbackAndHonoursAPISelection() throws {
    let codex = try MeetingPostProcessingClientFactory.makeClient(
      configuration: ModelConfiguration(),
      environment: [:],
      log: { _ in }
    )
    #expect(codex is FallbackPostProcessingClient)

    let api = try MeetingPostProcessingClientFactory.makeClient(
      configuration: ModelConfiguration(
        baseURLReference: "https://example.invalid/v1",
        apiKeyReference: "test-key",
        modelsReference: "api-pro",
        postProcessingBackend: .api
      ),
      environment: [:],
      log: { _ in }
    )
    #expect(api is LLMChatClient)
  }

  @Test
  func backendSelectionPersistsAndDefaultsToCodex() {
    let suiteName = "WalleBrain.FallbackPostProcessingClientTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      Issue.record("Failed to create isolated UserDefaults suite.")
      return
    }
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let store = ModelConfigurationStore(defaults: defaults)

    #expect(store.load().postProcessingBackend == .codex)
    #expect(store.load().codexExecutablePath.isEmpty)

    var configuration = store.load()
    configuration.postProcessingBackend = .api
    configuration.codexExecutablePath = "/opt/codex/bin/codex"
    configuration.codexModel = "gpt-test"
    store.save(configuration)

    let loaded = store.load()
    #expect(loaded.postProcessingBackend == .api)
    #expect(loaded.codexExecutablePath == "/opt/codex/bin/codex")
    #expect(loaded.codexModel == "gpt-test")
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
    acceptedModels?.contains(model) ?? true
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
