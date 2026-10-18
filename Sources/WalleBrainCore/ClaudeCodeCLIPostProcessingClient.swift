import Foundation

/// Runs WalleBrain's post-processing prompts through the local Claude Code CLI (`claude -p`), using the user's
/// Claude login.
///
/// Every run is locked down: no tools at all (`--tools ""`), `--safe-mode` (no CLAUDE.md, hooks, plugins, skills
/// or MCP servers from user/project config), `--strict-mcp-config` with no MCP config, `--permission-mode dontAsk`,
/// `--no-session-persistence`, and a fresh `LocalCLIWorkspace` as the working directory. The prompt goes over
/// stdin and the system prompt replaces Claude Code's default agent prompt.
public actor ClaudeCodeCLIPostProcessingClient: MeetingPostProcessingClient {
  public static let tool = LocalCLITool.claudeCode
  public static let providerLabel = tool.displayName
  static let fallbackModelLabel = "claude-default"

  private let options: LocalCLIOptions
  private let environment: [String: String]
  private let resolver: CLIExecutableResolver
  private let runner: any CLIProcessRunning
  private var resolvedExecutable: LocalCLIExecutable?

  public init(
    options: LocalCLIOptions = LocalCLIOptions(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runner: any CLIProcessRunning = SystemCLIProcessRunner(),
    resolver: CLIExecutableResolver? = nil
  ) {
    self.options = options
    self.environment = environment
    self.runner = runner
    self.resolver = resolver ?? CLIExecutableResolver(
      tool: Self.tool,
      configuredPath: options.executablePath,
      environmentPATH: environment["PATH"]
    )
  }

  /// Finds the first candidate binary that answers `claude --version`.
  public func resolveExecutable() async throws -> LocalCLIExecutable {
    if let resolvedExecutable {
      return resolvedExecutable
    }
    let executable = try await LocalCLISupport.resolveExecutable(
      resolver: resolver,
      runner: runner,
      environment: Self.childEnvironment(from: environment),
      timeout: options.versionCheckTimeout
    )
    resolvedExecutable = executable
    return executable
  }

  public func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult {
    let glossary = MeetingPostProcessingPrompts.glossaryText(from: dictionary)
    let run = try await execute(
      systemPrompt: MeetingPostProcessingPrompts.organizeSystemPrompt,
      prompt: MeetingPostProcessingPrompts.organizeUserPrompt(transcript: transcript, glossary: glossary),
      workspaceFiles: ["transcript.txt": transcript, "glossary.txt": glossary],
      outputSchema: nil,
      timeout: options.organizeTimeout
    )

    return OrganizedTranscriptResult(
      provider: Self.providerLabel,
      model: run.model,
      transcript: try LocalCLISupport.acceptOrganizedTranscript(run.message, sourceTranscript: transcript, tool: Self.tool)
    )
  }

  /// `preferredModel` is ignored: it may name another backend's model, and Claude Code should use its own.
  public func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult {
    let organizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let run = try await execute(
      systemPrompt: MeetingPostProcessingPrompts.analysisSystemPrompt + "\nUse `null` for unknown optional string fields.",
      prompt: MeetingPostProcessingPrompts.analysisUserPrompt(transcript: organizedTranscript),
      workspaceFiles: ["transcript.txt": organizedTranscript],
      outputSchema: LocalCLISupport.analysisOutputSchema,
      timeout: options.analysisTimeout
    )

    return try LLMChatClient.parseAnalysisResult(
      content: run.message,
      provider: Self.providerLabel,
      model: run.model,
      organizedTranscript: organizedTranscript
    )
  }

  public func acceptsPreferredModel(_ model: String) async -> Bool {
    false
  }

  // MARK: - Execution

  private func execute(
    systemPrompt: String,
    prompt: String,
    workspaceFiles: [String: String],
    outputSchema: String?,
    timeout: Duration
  ) async throws -> ClaudePrintResult {
    let executable = try await resolveExecutable()
    let workspace = try LocalCLIWorkspace.make(files: workspaceFiles)
    defer { workspace.remove() }

    let output = try await runner.run(
      CLIProcessInvocation(
        executableURL: URL(fileURLWithPath: executable.path),
        arguments: Self.makePrintArguments(
          systemPrompt: systemPrompt + "\n" + LocalCLISupport.executionPreamble,
          outputSchema: outputSchema,
          model: options.model
        ),
        environment: LocalCLISupport.makeProcessEnvironment(
          base: Self.childEnvironment(from: environment),
          executablePath: executable.path,
          searchDirectories: resolver.fallbackSearchDirectories
        ),
        workingDirectory: workspace.workspace,
        standardInput: Data(prompt.utf8),
        timeout: timeout
      )
    )

    return try Self.interpret(output: output, configuredModel: options.model)
  }

  // MARK: - Pure helpers (unit-tested)

  struct ClaudePrintResult: Equatable {
    let message: String
    let model: String
  }

  static func makePrintArguments(
    systemPrompt: String,
    outputSchema: String?,
    model: String?
  ) -> [String] {
    var arguments = [
      "--print",
      "--output-format", "json",
      "--no-session-persistence",
      // No CLAUDE.md, hooks, plugins, skills, MCP servers or custom agents from user/project config.
      "--safe-mode",
      "--strict-mcp-config",
      "--disable-slash-commands",
      // No tools at all: the transcript is in the prompt, so nothing needs to be read, run or written.
      "--tools", "",
      "--permission-mode", "dontAsk",
      "--system-prompt", systemPrompt,
    ]
    if let outputSchema {
      arguments += ["--json-schema", outputSchema]
    }
    if let model = model?.trimmedNonEmpty {
      arguments += ["--model", model]
    }
    // The prompt itself is read from stdin: transcripts can exceed argument-length limits.
    return arguments
  }

  /// Drops variables inherited from a parent Claude Code session (e.g. when WalleBrain tools are launched from
  /// one): they would point the child at the host session's proxy or force bare mode.
  static func childEnvironment(from base: [String: String]) -> [String: String] {
    let inheritedFromHostSession = base["CLAUDECODE"] != nil
    return base.filter { key, _ in
      if key == "CLAUDECODE" || key == "CLAUDE_PID" || key == "CLAUDE_EFFORT" {
        return false
      }
      if key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK") || key.hasPrefix("CLAUDE_PREVIEW") {
        return false
      }
      if inheritedFromHostSession, key == "ANTHROPIC_BASE_URL" {
        return false
      }
      return true
    }
  }

  /// Interprets `claude --print --output-format json` output: a single result object with `is_error`, `result`,
  /// optional `structured_output` (with `--json-schema`) and `modelUsage` keyed by model name.
  static func interpret(output: CLIProcessOutput, configuredModel: String?) throws -> ClaudePrintResult {
    let tool = providerLabel
    guard let payload = jsonObject(in: output.standardOutput) else {
      if output.exitCode != 0 {
        throw classifyFailure(
          exitCode: output.exitCode,
          details: LocalCLISupport.tail(of: output.standardError.isEmpty ? output.standardOutput : output.standardError, maxLines: 12)
        )
      }
      let text = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else {
        throw LocalCLIError.emptyOutput(tool: tool)
      }
      return ClaudePrintResult(message: text, model: configuredModel ?? fallbackModelLabel)
    }

    let resultText = (payload["result"] as? String) ?? ""
    if payload["is_error"] as? Bool == true || output.exitCode != 0 {
      let details = resultText.trimmedNonEmpty
        ?? LocalCLISupport.tail(of: output.standardError, maxLines: 12)
      throw classifyFailure(exitCode: output.exitCode == 0 ? 1 : output.exitCode, details: details)
    }

    var message = resultText
    if
      let structured = payload["structured_output"],
      JSONSerialization.isValidJSONObject(structured),
      let data = try? JSONSerialization.data(withJSONObject: structured)
    {
      message = String(decoding: data, as: UTF8.self)
    }
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalCLIError.emptyOutput(tool: tool)
    }

    return ClaudePrintResult(
      message: message,
      model: primaryModel(in: payload) ?? configuredModel ?? fallbackModelLabel
    )
  }

  /// The model that produced the most output tokens (the main model rather than a helper model).
  static func primaryModel(in payload: [String: Any]) -> String? {
    guard let usage = payload["modelUsage"] as? [String: Any], !usage.isEmpty else {
      return nil
    }
    func outputTokens(_ model: String) -> Double {
      let entry = usage[model] as? [String: Any]
      return (entry?["outputTokens"] as? NSNumber)?.doubleValue ?? 0
    }
    return usage.keys.sorted().max { outputTokens($0) < outputTokens($1) }
  }

  private static func classifyFailure(exitCode: Int32, details: String) -> LocalCLIError {
    LocalCLISupport.failure(tool: tool, exitCode: exitCode, details: details, loginHint: "Run `claude auth login` in a terminal.")
  }

  private static func jsonObject(in text: String) -> [String: Any]? {
    guard
      let start = text.firstIndex(of: "{"),
      let end = text.lastIndex(of: "}"),
      start < end
    else {
      return nil
    }
    let data = Data(text[start...end].utf8)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }
}
