import Foundation
import Testing
@testable import WalleBrainCore

struct CodexCLIPostProcessingClientTests {
  // MARK: - Argument building

  @Test
  func execArgumentsUseReadOnlyEphemeralSandboxAndStdinPrompt() {
    let arguments = CodexCLIPostProcessingClient.makeExecArguments(
      workspace: URL(fileURLWithPath: "/tmp/wb/workspace"),
      lastMessageFile: URL(fileURLWithPath: "/tmp/wb/io/last-message.txt"),
      outputSchemaFile: URL(fileURLWithPath: "/tmp/wb/io/output-schema.json"),
      model: "gpt-test"
    )

    #expect(arguments.first == "exec")
    #expect(arguments.last == "-")
    #expect(value(after: "--sandbox", in: arguments) == "read-only")
    #expect(value(after: "--cd", in: arguments) == "/tmp/wb/workspace")
    #expect(value(after: "--output-last-message", in: arguments) == "/tmp/wb/io/last-message.txt")
    #expect(value(after: "--output-schema", in: arguments) == "/tmp/wb/io/output-schema.json")
    #expect(value(after: "--model", in: arguments) == "gpt-test")
    #expect(arguments.contains("--ephemeral"))
    #expect(arguments.contains("--skip-git-repo-check"))
    #expect(!arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    #expect(!arguments.contains("workspace-write"))
    #expect(!arguments.contains("danger-full-access"))
  }

  @Test
  func execArgumentsOmitSchemaAndBlankModel() {
    let arguments = CodexCLIPostProcessingClient.makeExecArguments(
      workspace: URL(fileURLWithPath: "/tmp/wb/workspace"),
      lastMessageFile: URL(fileURLWithPath: "/tmp/wb/io/last-message.txt"),
      outputSchemaFile: nil,
      model: "  "
    )

    #expect(!arguments.contains("--output-schema"))
    #expect(!arguments.contains("--model"))
  }

  @Test
  func processEnvironmentPutsBinaryDirectoryAndInstallLocationsOnPATH() {
    let resolver = CLIExecutableResolver(
      tool: .codex,
      configuredPath: nil,
      environmentPATH: nil,
      homeDirectory: "/Users/test",
      fileSystem: FakeFileSystem().fileSystem
    )
    let environment = LocalCLISupport.makeProcessEnvironment(
      base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
      executablePath: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
      searchDirectories: resolver.fallbackSearchDirectories
    )

    let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    #expect(path.first == "/opt/homebrew/lib/node_modules/@openai/codex/bin")
    #expect(path.contains("/opt/homebrew/bin"))
    #expect(path.contains("/Users/test/.local/bin"))
    #expect(path.filter { $0 == "/usr/bin" }.count == 1)
    #expect(environment["HOME"] == "/Users/test")
  }

  // MARK: - Output parsing

  @Test
  func parsesModelFromStandardErrorHeaderOnly() {
    let stderr = """
    OpenAI Codex v0.163.0
    --------
    workdir: /tmp/wb/workspace
    model: gpt-6-astra
    provider: openai
    --------
    user
    model: injected-from-prompt
    """
    #expect(CodexCLIPostProcessingClient.parseModel(fromStandardError: stderr) == "gpt-6-astra")

    let promptOnly = """
    user
    model: injected-from-prompt
    """
    #expect(CodexCLIPostProcessingClient.parseModel(fromStandardError: promptOnly) == nil)
  }

  @Test
  func parsesAnalysisMessageIntoPostProcessingResult() throws {
    let message = """
    {
      "summary": "会议确认 Atlas 下周上线。",
      "keyPoints": ["Atlas 下周上线"],
      "actionItems": ["补齐发布 checklist"],
      "decisions": [{"text": "Atlas 下周上线", "status": "confirmed", "confidence": 0.9, "relatedProjectID": "atlas-launch", "evidence": null}],
      "openLoops": [{"type": "actionItem", "text": "补齐发布 checklist", "owner": null, "dueHint": "本周", "status": "open", "relatedProjectID": null, "evidence": null}],
      "risks": [],
      "participantPositions": [],
      "projectLinks": [{"project": {"id": "atlas-launch", "title": "Atlas", "aliases": []}, "role": "primary", "status": "confirmed", "confidence": 0.8, "evidence": null}],
      "relatedPeople": []
    }
    """

    let result = try CodexCLIPostProcessingClient.parseAnalysis(
      message: message,
      model: "gpt-6-astra",
      organizedTranscript: "A：我们决定 Atlas 下周上线。"
    )

    #expect(result.provider == "Codex CLI")
    #expect(result.model == "gpt-6-astra")
    #expect(result.summary == "会议确认 Atlas 下周上线。")
    #expect(result.keyPoints == ["Atlas 下周上线"])
    #expect(result.decisions.map(\.status) == [.confirmed])
    #expect(result.openLoops.first?.dueHint == "本周")
    #expect(result.openLoops.first?.owner == nil)
    #expect(result.projectLinks.first?.project.id == "atlas-launch")
    #expect(result.organizedTranscript == "A：我们决定 Atlas 下周上线。")
  }

  @Test
  func rejectsUnparseableAnalysisMessage() {
    #expect(throws: (any Error).self) {
      try CodexCLIPostProcessingClient.parseAnalysis(message: "Sorry, I cannot help.", model: "m", organizedTranscript: "A：你好")
    }
    #expect(throws: (any Error).self) {
      try CodexCLIPostProcessingClient.parseAnalysis(message: "{\"keyPoints\": []}", model: "m", organizedTranscript: "A：你好")
    }
  }

  @Test
  func analysisOutputSchemaIsStrictEverywhere() throws {
    let schema = try #require(
      try JSONSerialization.jsonObject(with: Data(LocalCLISupport.analysisOutputSchema.utf8)) as? [String: Any]
    )
    let topLevel = try #require(schema["properties"] as? [String: Any])
    #expect(Set(topLevel.keys) == [
      "summary", "keyPoints", "actionItems", "decisions", "openLoops", "risks",
      "participantPositions", "projectLinks", "relatedPeople",
    ])
    assertStrictObjects(in: schema)
  }

  // MARK: - Binary resolution

  @Test
  func searchLocationsFollowConfiguredThenPATHThenFallbackDirectories() {
    let resolver = CLIExecutableResolver(
      configuredPath: "~/tools/codex",
      environmentPATH: "/usr/bin:/opt/homebrew/bin:/custom/bin",
      homeDirectory: "/Users/test",
      fileSystem: FakeFileSystem().fileSystem
    )

    #expect(resolver.searchLocations() == [
      "/Users/test/tools/codex",
      "/usr/bin/codex",
      "/opt/homebrew/bin/codex",
      "/custom/bin/codex",
      "/usr/local/bin/codex",
      "/Users/test/.local/bin/codex",
    ])
  }

  @Test
  func configuredDirectoryResolvesToCodexInside() {
    let fake = FakeFileSystem(directories: ["/Applications/Tools"])
    let resolver = CLIExecutableResolver(
      configuredPath: "/Applications/Tools",
      environmentPATH: nil,
      homeDirectory: "/Users/test",
      fileSystem: fake.fileSystem
    )

    #expect(resolver.searchLocations().first == "/Applications/Tools/codex")
  }

  @Test
  func npmWrapperExpandsToNativeBinariesFirst() {
    let wrapper = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
    let native = CLIExecutableResolver.nativeBinaryCandidates(forWrapperAt: wrapper)
      .first { $0.hasSuffix("/bin/codex") && $0.contains("node_modules/@openai/codex/node_modules") }!
    let fake = FakeFileSystem(
      executables: ["/opt/homebrew/bin/codex", native, "/Users/test/.local/bin/codex"],
      symlinks: ["/opt/homebrew/bin/codex": wrapper]
    )
    let resolver = CLIExecutableResolver(
      configuredPath: nil,
      environmentPATH: "/usr/bin",
      homeDirectory: "/Users/test",
      fileSystem: fake.fileSystem
    )

    #expect(resolver.executableCandidates() == [native, "/opt/homebrew/bin/codex", "/Users/test/.local/bin/codex"])
  }

  @Test
  func resolveExecutableSkipsBrokenCandidatesUsingVersionCheck() async throws {
    let fake = FakeFileSystem(executables: ["/usr/local/bin/codex", "/Users/test/.local/bin/codex"])
    let runner = FakeCLIRunner { invocation in
      #expect(invocation.arguments == ["--version"])
      if invocation.executableURL.path == "/usr/local/bin/codex" {
        return CLIProcessOutput(exitCode: 1, standardOutput: "", standardError: "Error: spawn codex ENOENT")
      }
      return CLIProcessOutput(exitCode: 0, standardOutput: "codex-cli 9.9.9\n", standardError: "")
    }
    let client = makeClient(fileSystem: fake, runner: runner)

    let executable = try await client.resolveExecutable()

    #expect(executable == LocalCLIExecutable(path: "/Users/test/.local/bin/codex", version: "codex-cli 9.9.9"))
    _ = try await client.resolveExecutable()
    #expect(await runner.invocations.count == 2)
  }

  @Test
  func resolveExecutableReportsMissingAndUnusableBinaries() async {
    let missing = makeClient(fileSystem: FakeFileSystem(), runner: FakeCLIRunner { _ in
      Issue.record("Runner must not be called without candidates.")
      return CLIProcessOutput(exitCode: 0, standardOutput: "", standardError: "")
    })
    await #expect(throws: LocalCLIError.self) {
      try await missing.resolveExecutable()
    }

    let broken = makeClient(
      fileSystem: FakeFileSystem(executables: ["/opt/homebrew/bin/codex"]),
      runner: FakeCLIRunner { _ in CLIProcessOutput(exitCode: 1, standardOutput: "", standardError: "ENOENT") }
    )
    do {
      _ = try await broken.resolveExecutable()
      Issue.record("Expected an unusable-binary error.")
    } catch let error as LocalCLIError {
      #expect(error.isUnavailable)
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  // MARK: - End-to-end with a fake runner

  @Test
  func organizeRunsCodexInIsolatedWorkspaceAndRecordsModel() async throws {
    let fixture = Self.transcriptFixture()
    let runner = FakeCLIRunner { invocation in
      if invocation.arguments == ["--version"] {
        return CLIProcessOutput(exitCode: 0, standardOutput: "codex-cli 1.0.0", standardError: "")
      }

      let workspace = URL(fileURLWithPath: try #require(value(after: "--cd", in: invocation.arguments)))
      #expect(invocation.workingDirectory.standardizedFileURL == workspace.standardizedFileURL)
      let files = try FileManager.default.contentsOfDirectory(atPath: workspace.path).sorted()
      #expect(files == ["glossary.txt", "transcript.txt"])
      #expect(try String(contentsOf: workspace.appending(path: "transcript.txt"), encoding: .utf8) == fixture.source)
      #expect(String(decoding: invocation.standardInput ?? Data(), as: UTF8.self).contains(fixture.source))

      let outputFile = try #require(value(after: "--output-last-message", in: invocation.arguments))
      try fixture.organized.write(toFile: outputFile, atomically: true, encoding: .utf8)
      return CLIProcessOutput(
        exitCode: 0,
        standardOutput: "",
        standardError: "--------\nmodel: gpt-6-astra\nprovider: openai\n--------\nuser\n..."
      )
    }
    let client = makeClient(
      fileSystem: FakeFileSystem(executables: ["/opt/homebrew/bin/codex"]),
      runner: runner
    )

    let result = try await client.organizeTranscript(
      transcript: fixture.source,
      dictionary: TermDictionary(title: "Test", entries: [])
    )

    #expect(result.provider == "Codex CLI")
    #expect(result.model == "gpt-6-astra")
    #expect(result.transcript == fixture.organized)
  }

  @Test
  func organizeFailsOnProcessErrorAndOnLowQualityOutput() async {
    let fixture = Self.transcriptFixture()
    let failing = makeClient(
      fileSystem: FakeFileSystem(executables: ["/opt/homebrew/bin/codex"]),
      runner: FakeCLIRunner { invocation in
        if invocation.arguments == ["--version"] {
          return CLIProcessOutput(exitCode: 0, standardOutput: "codex-cli 1.0.0", standardError: "")
        }
        return CLIProcessOutput(exitCode: 1, standardOutput: "", standardError: "ERROR: stream disconnected")
      }
    )
    await #expect(throws: LocalCLIError.processFailed(tool: "Codex CLI", exitCode: 1, details: "ERROR: stream disconnected")) {
      try await failing.organizeTranscript(transcript: fixture.source, dictionary: TermDictionary(title: "T", entries: []))
    }

    let truncated = makeClient(
      fileSystem: FakeFileSystem(executables: ["/opt/homebrew/bin/codex"]),
      runner: FakeCLIRunner { invocation in
        if invocation.arguments == ["--version"] {
          return CLIProcessOutput(exitCode: 0, standardOutput: "codex-cli 1.0.0", standardError: "")
        }
        return CLIProcessOutput(exitCode: 0, standardOutput: "A：太短了。", standardError: "")
      }
    )
    await #expect(throws: WalleBrainError.self) {
      try await truncated.organizeTranscript(transcript: fixture.source, dictionary: TermDictionary(title: "T", entries: []))
    }
  }

  @Test
  func unauthorizedRunMarksCodexUnavailable() async {
    let fixture = Self.transcriptFixture()
    let client = makeClient(
      fileSystem: FakeFileSystem(executables: ["/opt/homebrew/bin/codex"]),
      runner: FakeCLIRunner { invocation in
        if invocation.arguments == ["--version"] {
          return CLIProcessOutput(exitCode: 0, standardOutput: "codex-cli 1.0.0", standardError: "")
        }
        return CLIProcessOutput(
          exitCode: 1,
          standardOutput: "",
          standardError: "ERROR: unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"
        )
      }
    )

    do {
      _ = try await client.organizeTranscript(transcript: fixture.source, dictionary: TermDictionary(title: "T", entries: []))
      Issue.record("Expected a not-authenticated error.")
    } catch let error as LocalCLIError {
      #expect(error.isUnavailable)
      #expect(error.localizedDescription.contains("codex login"))
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  // MARK: - Helpers

  private func makeClient(fileSystem: FakeFileSystem, runner: FakeCLIRunner) -> CodexCLIPostProcessingClient {
    CodexCLIPostProcessingClient(
      options: LocalCLIOptions(),
      environment: ["PATH": "/usr/bin", "HOME": "/Users/test"],
      runner: runner,
      resolver: CLIExecutableResolver(
        configuredPath: nil,
        environmentPATH: "/usr/bin",
        homeDirectory: "/Users/test",
        fileSystem: fileSystem.fileSystem
      )
    )
  }

  static func transcriptFixture() -> (source: String, organized: String) {
    let source = (0 ..< 50)
      .map { "第\($0 + 1)段讨论神策AI增长团队、客户世界模型和融资安排。" }
      .joined(separator: "\n")
    let organized = (0 ..< 30)
      .map { "A：第\($0 + 1)部分讨论神策AI增长团队与客户世界模型。" }
      .joined(separator: "\n")
    return (source, organized)
  }

  private func assertStrictObjects(in node: Any, path: String = "$") {
    if let array = node as? [Any] {
      for (index, element) in array.enumerated() {
        assertStrictObjects(in: element, path: "\(path)[\(index)]")
      }
      return
    }
    guard let dictionary = node as? [String: Any] else {
      return
    }
    if dictionary["type"] as? String == "object" {
      let properties = (dictionary["properties"] as? [String: Any]) ?? [:]
      let required = Set((dictionary["required"] as? [String]) ?? [])
      #expect(dictionary["additionalProperties"] as? Bool == false, "\(path) must forbid additional properties")
      #expect(required == Set(properties.keys), "\(path) must require every property")
    }
    for (key, value) in dictionary {
      assertStrictObjects(in: value, path: "\(path).\(key)")
    }
  }
}

func value(after flag: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
    return nil
  }
  return arguments[index + 1]
}

struct FakeFileSystem: Sendable {
  var executables: Set<String> = []
  var directories: Set<String> = []
  var symlinks: [String: String] = [:]

  var fileSystem: CLIFileSystem {
    let executables = executables
    let directories = directories
    let symlinks = symlinks
    return CLIFileSystem(
      isExecutableFile: { executables.contains($0) },
      isDirectory: { directories.contains($0) },
      resolvingSymlinks: { symlinks[$0] ?? $0 }
    )
  }
}

actor FakeCLIRunner: CLIProcessRunning {
  private let handler: @Sendable (CLIProcessInvocation) throws -> CLIProcessOutput
  private(set) var invocations: [CLIProcessInvocation] = []

  init(handler: @escaping @Sendable (CLIProcessInvocation) throws -> CLIProcessOutput) {
    self.handler = handler
  }

  func run(_ invocation: CLIProcessInvocation) async throws -> CLIProcessOutput {
    invocations.append(invocation)
    return try handler(invocation)
  }
}
