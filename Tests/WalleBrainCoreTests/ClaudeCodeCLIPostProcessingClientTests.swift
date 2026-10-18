import Foundation
import Testing
@testable import WalleBrainCore

struct ClaudeCodeCLIPostProcessingClientTests {
  // MARK: - Argument building

  @Test
  func printArgumentsDisableToolsConfigAndPersistence() {
    let arguments = ClaudeCodeCLIPostProcessingClient.makePrintArguments(
      systemPrompt: "You output strict JSON only.",
      outputSchema: "{\"type\":\"object\"}",
      model: "opus"
    )

    #expect(arguments.first == "--print")
    #expect(value(after: "--output-format", in: arguments) == "json")
    #expect(value(after: "--tools", in: arguments) == "")
    #expect(value(after: "--permission-mode", in: arguments) == "dontAsk")
    #expect(value(after: "--system-prompt", in: arguments) == "You output strict JSON only.")
    #expect(value(after: "--json-schema", in: arguments) == "{\"type\":\"object\"}")
    #expect(value(after: "--model", in: arguments) == "opus")
    #expect(arguments.contains("--no-session-persistence"))
    #expect(arguments.contains("--safe-mode"))
    #expect(arguments.contains("--strict-mcp-config"))
    #expect(arguments.contains("--disable-slash-commands"))
    #expect(!arguments.contains("--mcp-config"))
    #expect(!arguments.contains("--dangerously-skip-permissions"))
    #expect(!arguments.contains("--allow-dangerously-skip-permissions"))
    #expect(!arguments.contains("--add-dir"))
  }

  @Test
  func printArgumentsOmitSchemaAndBlankModel() {
    let arguments = ClaudeCodeCLIPostProcessingClient.makePrintArguments(
      systemPrompt: "x",
      outputSchema: nil,
      model: " "
    )

    #expect(!arguments.contains("--json-schema"))
    #expect(!arguments.contains("--model"))
  }

  @Test
  func childEnvironmentDropsHostClaudeSessionVariables() {
    let hosted = ClaudeCodeCLIPostProcessingClient.childEnvironment(from: [
      "HOME": "/Users/test",
      "PATH": "/usr/bin",
      "CLAUDECODE": "1",
      "CLAUDE_CODE_SIMPLE": "1",
      "CLAUDE_CODE_SESSION_ID": "abc",
      "CLAUDE_AGENT_SDK_VERSION": "1",
      "CLAUDE_PID": "42",
      "ANTHROPIC_BASE_URL": "http://127.0.0.1:9999",
    ])
    #expect(hosted == ["HOME": "/Users/test", "PATH": "/usr/bin"])

    let standalone = ClaudeCodeCLIPostProcessingClient.childEnvironment(from: [
      "HOME": "/Users/test",
      "ANTHROPIC_BASE_URL": "https://gateway.example",
    ])
    #expect(standalone["ANTHROPIC_BASE_URL"] == "https://gateway.example")
  }

  @Test
  func searchLocationsPreferLocalBinForClaude() {
    let resolver = CLIExecutableResolver(
      tool: .claudeCode,
      configuredPath: "/custom/claude",
      environmentPATH: "/usr/bin",
      homeDirectory: "/Users/test",
      fileSystem: FakeFileSystem().fileSystem
    )

    #expect(resolver.searchLocations() == [
      "/custom/claude",
      "/usr/bin/claude",
      "/Users/test/.local/bin/claude",
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
    ])
  }

  // MARK: - Output interpretation

  @Test
  func interpretsStructuredOutputAndPicksMainModel() throws {
    let stdout = """
    {"type":"result","subtype":"success","is_error":false,"result":"","structured_output":{"summary":"会议确认 Atlas 下周上线。","keyPoints":["Atlas 下周上线"],"actionItems":[],"decisions":[],"openLoops":[],"risks":[],"participantPositions":[],"projectLinks":[],"relatedPeople":[]},"modelUsage":{"claude-haiku-5-5":{"outputTokens":12},"claude-opus-5-5":{"outputTokens":900}}}
    """

    let result = try ClaudeCodeCLIPostProcessingClient.interpret(
      output: CLIProcessOutput(exitCode: 0, standardOutput: stdout, standardError: ""),
      configuredModel: nil
    )
    #expect(result.model == "claude-opus-5-5")

    let analysis = try LLMChatClient.parseAnalysisResult(
      content: result.message,
      provider: ClaudeCodeCLIPostProcessingClient.providerLabel,
      model: result.model,
      organizedTranscript: "A：我们决定 Atlas 下周上线。"
    )
    #expect(analysis.provider == "Claude Code CLI")
    #expect(analysis.summary == "会议确认 Atlas 下周上线。")
    #expect(analysis.keyPoints == ["Atlas 下周上线"])
  }

  @Test
  func interpretsPlainResultTextAndFallsBackToConfiguredModel() throws {
    let stdout = #"{"type":"result","is_error":false,"result":"A：整理后的会议记录。","modelUsage":{}}"#

    let result = try ClaudeCodeCLIPostProcessingClient.interpret(
      output: CLIProcessOutput(exitCode: 0, standardOutput: stdout, standardError: ""),
      configuredModel: "sonnet"
    )

    #expect(result == .init(message: "A：整理后的会议记录。", model: "sonnet"))
  }

  @Test
  func classifiesLoggedOutAsUnavailable() {
    let stdout = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login","modelUsage":{}}"#

    do {
      _ = try ClaudeCodeCLIPostProcessingClient.interpret(
        output: CLIProcessOutput(exitCode: 1, standardOutput: stdout, standardError: ""),
        configuredModel: nil
      )
      Issue.record("Expected a not-authenticated error.")
    } catch let error as LocalCLIError {
      guard case .notAuthenticated = error else {
        Issue.record("Unexpected error \(error)")
        return
      }
      #expect(error.isUnavailable)
      #expect(error.localizedDescription.contains("claude auth login"))
    } catch {
      Issue.record("Unexpected error \(error)")
    }
  }

  @Test
  func classifiesOtherFailuresAsRetryable() {
    let apiError = #"{"type":"result","is_error":true,"result":"API Error: 529 overloaded","modelUsage":{}}"#
    #expect(throws: LocalCLIError.processFailed(tool: "Claude Code CLI", exitCode: 1, details: "API Error: 529 overloaded")) {
      try ClaudeCodeCLIPostProcessingClient.interpret(
        output: CLIProcessOutput(exitCode: 0, standardOutput: apiError, standardError: ""),
        configuredModel: nil
      )
    }

    #expect(throws: LocalCLIError.processFailed(tool: "Claude Code CLI", exitCode: 2, details: "error: unknown option '--bogus'")) {
      try ClaudeCodeCLIPostProcessingClient.interpret(
        output: CLIProcessOutput(exitCode: 2, standardOutput: "", standardError: "error: unknown option '--bogus'\n"),
        configuredModel: nil
      )
    }

    #expect(throws: LocalCLIError.emptyOutput(tool: "Claude Code CLI")) {
      try ClaudeCodeCLIPostProcessingClient.interpret(
        output: CLIProcessOutput(exitCode: 0, standardOutput: #"{"is_error":false,"result":"  "}"#, standardError: ""),
        configuredModel: nil
      )
    }
  }

  // MARK: - End-to-end with a fake runner

  @Test
  func organizeSendsTranscriptOnStdinFromIsolatedWorkspace() async throws {
    let fixture = CodexCLIPostProcessingClientTests.transcriptFixture()
    let organizedJSON = try String(
      decoding: JSONSerialization.data(withJSONObject: [
        "type": "result",
        "is_error": false,
        "result": fixture.organized,
        "modelUsage": ["claude-opus-5-5": ["outputTokens": 2000]],
      ]),
      as: UTF8.self
    )
    let runner = FakeCLIRunner { invocation in
      if invocation.arguments == ["--version"] {
        #expect(invocation.environment["CLAUDECODE"] == nil)
        return CLIProcessOutput(exitCode: 0, standardOutput: "2.1.220 (Claude Code)\n", standardError: "")
      }

      #expect(invocation.environment["CLAUDECODE"] == nil)
      #expect(!invocation.arguments.contains { $0.contains(fixture.source) })
      #expect(String(decoding: invocation.standardInput ?? Data(), as: UTF8.self).contains(fixture.source))
      let files = try FileManager.default.contentsOfDirectory(atPath: invocation.workingDirectory.path).sorted()
      #expect(files == ["glossary.txt", "transcript.txt"])
      return CLIProcessOutput(exitCode: 0, standardOutput: organizedJSON, standardError: "")
    }
    let client = ClaudeCodeCLIPostProcessingClient(
      options: LocalCLIOptions(),
      environment: ["PATH": "/usr/bin", "HOME": "/Users/test", "CLAUDECODE": "1"],
      runner: runner,
      resolver: CLIExecutableResolver(
        tool: .claudeCode,
        configuredPath: nil,
        environmentPATH: "/usr/bin",
        homeDirectory: "/Users/test",
        fileSystem: FakeFileSystem(executables: ["/Users/test/.local/bin/claude"]).fileSystem
      )
    )

    let result = try await client.organizeTranscript(
      transcript: fixture.source,
      dictionary: TermDictionary(title: "Test", entries: [])
    )

    #expect(result.provider == "Claude Code CLI")
    #expect(result.model == "claude-opus-5-5")
    #expect(result.transcript == fixture.organized)
    #expect(try await client.resolveExecutable() == LocalCLIExecutable(path: "/Users/test/.local/bin/claude", version: "2.1.220 (Claude Code)"))
  }
}
