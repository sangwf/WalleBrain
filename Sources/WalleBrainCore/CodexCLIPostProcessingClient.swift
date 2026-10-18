import Foundation

/// Runs WalleBrain's post-processing prompts through the local Codex CLI (`codex exec`), so the user's
/// Codex subscription and its current default model do the work.
///
/// Each call gets a fresh `LocalCLIWorkspace`: `workspace/` holds only the transcript (and glossary) text and is
/// Codex's working root; `io/` holds the output schema and the final-message file. Codex runs with the read-only
/// sandbox, `--ephemeral`, and never sees the repository or runtime directories as a workspace.
public actor CodexCLIPostProcessingClient: MeetingPostProcessingClient {
  public static let tool = LocalCLITool.codex
  public static let providerLabel = tool.displayName
  static let fallbackModelLabel = "codex-default"

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

  /// Finds the first candidate binary that answers `codex --version`.
  public func resolveExecutable() async throws -> LocalCLIExecutable {
    if let resolvedExecutable {
      return resolvedExecutable
    }
    let executable = try await LocalCLISupport.resolveExecutable(
      resolver: resolver,
      runner: runner,
      environment: environment,
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
      prompt: Self.organizePrompt(transcript: transcript, glossary: glossary),
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

  /// `preferredModel` is ignored: it may name another backend's model, and Codex should use its own.
  public func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult {
    let organizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let run = try await execute(
      prompt: Self.analysisPrompt(transcript: organizedTranscript),
      workspaceFiles: ["transcript.txt": organizedTranscript],
      outputSchema: LocalCLISupport.analysisOutputSchema,
      timeout: options.analysisTimeout
    )

    return try Self.parseAnalysis(
      message: run.message,
      model: run.model,
      organizedTranscript: organizedTranscript
    )
  }

  public func acceptsPreferredModel(_ model: String) async -> Bool {
    false
  }

  // MARK: - Execution

  private struct RunResult {
    let message: String
    let model: String
  }

  private func execute(
    prompt: String,
    workspaceFiles: [String: String],
    outputSchema: String?,
    timeout: Duration
  ) async throws -> RunResult {
    let executable = try await resolveExecutable()
    let workspace = try LocalCLIWorkspace.make(files: workspaceFiles)
    defer { workspace.remove() }

    let lastMessageFile = workspace.io.appending(path: "last-message.txt", directoryHint: .notDirectory)
    var schemaFile: URL?
    if let outputSchema {
      let url = workspace.io.appending(path: "output-schema.json", directoryHint: .notDirectory)
      try Data(outputSchema.utf8).write(to: url)
      schemaFile = url
    }

    let output = try await runner.run(
      CLIProcessInvocation(
        executableURL: URL(fileURLWithPath: executable.path),
        arguments: Self.makeExecArguments(
          workspace: workspace.workspace,
          lastMessageFile: lastMessageFile,
          outputSchemaFile: schemaFile,
          model: options.model
        ),
        environment: LocalCLISupport.makeProcessEnvironment(
          base: environment,
          executablePath: executable.path,
          searchDirectories: resolver.fallbackSearchDirectories
        ),
        workingDirectory: workspace.workspace,
        standardInput: Data(prompt.utf8),
        timeout: timeout
      )
    )

    guard output.exitCode == 0 else {
      throw LocalCLISupport.failure(
        tool: Self.tool,
        exitCode: output.exitCode,
        details: LocalCLISupport.tail(of: output.standardError, maxLines: 12),
        loginHint: "Run `codex login` in a terminal."
      )
    }

    let fileMessage = (try? String(contentsOf: lastMessageFile, encoding: .utf8)) ?? ""
    let message = fileMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? output.standardOutput
      : fileMessage
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LocalCLIError.emptyOutput(tool: Self.providerLabel)
    }

    return RunResult(
      message: message,
      model: Self.parseModel(fromStandardError: output.standardError) ?? options.model ?? Self.fallbackModelLabel
    )
  }

  // MARK: - Pure helpers (unit-tested)

  static func makeExecArguments(
    workspace: URL,
    lastMessageFile: URL,
    outputSchemaFile: URL?,
    model: String?
  ) -> [String] {
    var arguments = [
      "exec",
      "--skip-git-repo-check",
      "--ephemeral",
      "--sandbox", "read-only",
      "--color", "never",
      "-c", "approval_policy=\"never\"",
      // The user's config may register a turn-ended notifier; post-processing runs should stay silent.
      "-c", "notify=[]",
      "--cd", workspace.path(percentEncoded: false),
      "--output-last-message", lastMessageFile.path(percentEncoded: false),
    ]
    if let outputSchemaFile {
      arguments += ["--output-schema", outputSchemaFile.path(percentEncoded: false)]
    }
    if let model = model?.trimmedNonEmpty {
      arguments += ["--model", model]
    }
    // The prompt is read from stdin: transcripts can exceed argument-length limits.
    arguments.append("-")
    return arguments
  }

  static func organizePrompt(transcript: String, glossary: String) -> String {
    """
    \(MeetingPostProcessingPrompts.organizeSystemPrompt)
    \(LocalCLISupport.executionPreamble)

    \(MeetingPostProcessingPrompts.organizeUserPrompt(transcript: transcript, glossary: glossary))
    """
  }

  static func analysisPrompt(transcript: String) -> String {
    """
    \(MeetingPostProcessingPrompts.analysisSystemPrompt)
    \(LocalCLISupport.executionPreamble)
    Use `null` for unknown optional string fields.

    \(MeetingPostProcessingPrompts.analysisUserPrompt(transcript: transcript))
    """
  }

  static func parseAnalysis(
    message: String,
    model: String,
    organizedTranscript: String
  ) throws -> LLMPostProcessingResult {
    try LLMChatClient.parseAnalysisResult(
      content: message,
      provider: providerLabel,
      model: model,
      organizedTranscript: organizedTranscript
    )
  }

  /// `codex exec` prints a header to stderr (`model: …`, `provider: …`, …) before echoing the prompt.
  static func parseModel(fromStandardError standardError: String) -> String? {
    for line in standardError.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "user" {
        break
      }
      if trimmed.hasPrefix("model:") {
        return String(trimmed.dropFirst("model:".count)).trimmedNonEmpty
      }
    }
    return nil
  }
}
