import Foundation

public enum CodexCLIError: Error, LocalizedError, Sendable, Equatable {
  case executableNotFound(searched: [String])
  case executableUnusable(details: [String])
  case processFailed(exitCode: Int32, details: String)
  case timedOut(seconds: Int)
  case emptyOutput

  /// The binary cannot run at all, so retrying Codex for later stages is pointless.
  public var isUnavailable: Bool {
    switch self {
    case .executableNotFound, .executableUnusable:
      return true
    case .processFailed, .timedOut, .emptyOutput:
      return false
    }
  }

  public var errorDescription: String? {
    switch self {
    case let .executableNotFound(searched):
      return "Codex CLI not found (searched \(searched.joined(separator: ", "))). Install it with `npm install -g @openai/codex`."
    case let .executableUnusable(details):
      return "Codex CLI is installed but not runnable: \(details.joined(separator: "; ")). Reinstall it with `npm install -g @openai/codex`."
    case let .processFailed(exitCode, details):
      return "codex exec exited with status \(exitCode): \(details)"
    case let .timedOut(seconds):
      return "codex exec timed out after \(seconds)s."
    case .emptyOutput:
      return "codex exec returned no final message."
    }
  }
}

public struct CodexExecutable: Sendable, Equatable {
  public let path: String
  public let version: String
}

public struct CodexCLIOptions: Sendable, Equatable {
  public var executablePath: String?
  /// `--model` override; nil uses the Codex CLI's configured default.
  public var model: String?
  public var organizeTimeout: Duration
  public var analysisTimeout: Duration
  public var versionCheckTimeout: Duration

  public init(
    executablePath: String? = nil,
    model: String? = nil,
    organizeTimeout: Duration = .seconds(30 * 60),
    analysisTimeout: Duration = .seconds(15 * 60),
    versionCheckTimeout: Duration = .seconds(20)
  ) {
    self.executablePath = executablePath?.trimmedNonEmpty
    self.model = model?.trimmedNonEmpty
    self.organizeTimeout = organizeTimeout
    self.analysisTimeout = analysisTimeout
    self.versionCheckTimeout = versionCheckTimeout
  }
}

/// Runs WalleBrain's post-processing prompts through the local Codex CLI (`codex exec`), so the user's
/// Codex subscription and its current default model do the work.
///
/// Each call gets a fresh temporary directory: `workspace/` holds only the transcript (and glossary) text and
/// is Codex's working root; `io/` holds the output schema and the final-message file. Codex runs with the
/// read-only sandbox, `--ephemeral`, and never sees the repository or runtime directories as a workspace.
public actor CodexCLIPostProcessingClient: MeetingPostProcessingClient {
  public static let providerLabel = "Codex CLI"
  static let fallbackModelLabel = "codex-default"

  private let options: CodexCLIOptions
  private let environment: [String: String]
  private let resolver: CodexExecutableResolver
  private let runner: any CodexProcessRunning
  private var resolvedExecutable: CodexExecutable?

  public init(
    options: CodexCLIOptions = CodexCLIOptions(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runner: any CodexProcessRunning = SystemCodexProcessRunner(),
    resolver: CodexExecutableResolver? = nil
  ) {
    self.options = options
    self.environment = environment
    self.runner = runner
    self.resolver = resolver ?? CodexExecutableResolver(
      configuredPath: options.executablePath,
      environmentPATH: environment["PATH"]
    )
  }

  /// Finds the first candidate binary that answers `codex --version`.
  public func resolveExecutable() async throws -> CodexExecutable {
    if let resolvedExecutable {
      return resolvedExecutable
    }

    let candidates = resolver.executableCandidates()
    guard !candidates.isEmpty else {
      throw CodexCLIError.executableNotFound(searched: resolver.searchLocations())
    }

    var failures: [String] = []
    for candidate in candidates {
      try Task.checkCancellation()
      do {
        let output = try await runner.run(
          CodexProcessInvocation(
            executableURL: URL(fileURLWithPath: candidate),
            arguments: ["--version"],
            environment: processEnvironment(executablePath: candidate),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: options.versionCheckTimeout
          )
        )
        let version = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.exitCode == 0, version.lowercased().hasPrefix("codex") {
          let executable = CodexExecutable(path: candidate, version: version)
          resolvedExecutable = executable
          return executable
        }
        failures.append("\(candidate): \(Self.tail(of: output.standardError.isEmpty ? output.standardOutput : output.standardError, maxLines: 2))")
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures.append("\(candidate): \(error.localizedDescription)")
      }
    }

    throw CodexCLIError.executableUnusable(details: failures)
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

    let organizedTranscript = run.message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !organizedTranscript.isEmpty else {
      throw CodexCLIError.emptyOutput
    }
    try OrganizedTranscriptQualityValidator.validate(
      organizedTranscript: organizedTranscript,
      sourceTranscript: transcript
    )

    return OrganizedTranscriptResult(
      provider: Self.providerLabel,
      model: run.model,
      transcript: organizedTranscript
    )
  }

  /// `preferredModel` is ignored: it may name an API model, and Codex should use its own configured model.
  public func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult {
    let organizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    let run = try await execute(
      prompt: Self.analysisPrompt(transcript: organizedTranscript),
      workspaceFiles: ["transcript.txt": organizedTranscript],
      outputSchema: Self.analysisOutputSchema,
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

    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appending(path: "WalleBrainCodex-\(UUID().uuidString)", directoryHint: .isDirectory)
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    let io = root.appending(path: "io", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: io, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    for (name, contents) in workspaceFiles {
      try Data(contents.utf8).write(to: workspace.appending(path: name, directoryHint: .notDirectory))
    }

    let lastMessageFile = io.appending(path: "last-message.txt", directoryHint: .notDirectory)
    var schemaFile: URL?
    if let outputSchema {
      let url = io.appending(path: "output-schema.json", directoryHint: .notDirectory)
      try Data(outputSchema.utf8).write(to: url)
      schemaFile = url
    }

    let output = try await runner.run(
      CodexProcessInvocation(
        executableURL: URL(fileURLWithPath: executable.path),
        arguments: Self.makeExecArguments(
          workspace: workspace,
          lastMessageFile: lastMessageFile,
          outputSchemaFile: schemaFile,
          model: options.model
        ),
        environment: processEnvironment(executablePath: executable.path),
        workingDirectory: workspace,
        standardInput: Data(prompt.utf8),
        timeout: timeout
      )
    )

    guard output.exitCode == 0 else {
      throw CodexCLIError.processFailed(
        exitCode: output.exitCode,
        details: Self.tail(of: output.standardError, maxLines: 12)
      )
    }

    let fileMessage = (try? String(contentsOf: lastMessageFile, encoding: .utf8)) ?? ""
    let message = fileMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? output.standardOutput
      : fileMessage
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CodexCLIError.emptyOutput
    }

    return RunResult(
      message: message,
      model: Self.parseModel(fromStandardError: output.standardError) ?? options.model ?? Self.fallbackModelLabel
    )
  }

  /// The GUI app's `PATH` usually lacks Homebrew; the npm wrapper needs `node`, so put the binary's own
  /// directory and the usual install locations on `PATH`.
  private func processEnvironment(executablePath: String) -> [String: String] {
    Self.makeProcessEnvironment(base: environment, executablePath: executablePath, homeDirectory: resolver.homeDirectory)
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

  static func makeProcessEnvironment(
    base: [String: String],
    executablePath: String,
    homeDirectory: String
  ) -> [String: String] {
    var environment = base
    let executableDirectory = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path(percentEncoded: false)
    var directories: [String] = [executableDirectory]
    directories += (base["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in CodexExecutableResolver.fallbackSearchDirectories {
      directories.append(directory.hasPrefix("~/") ? homeDirectory + "/" + directory.dropFirst(2) : directory)
    }
    directories += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    var seen: Set<String> = []
    var normalizedDirectories: [String] = []
    for directory in directories {
      let normalized = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
      if !normalized.isEmpty, seen.insert(normalized).inserted {
        normalizedDirectories.append(normalized)
      }
    }
    environment["PATH"] = normalizedDirectories.joined(separator: ":")
    environment["NO_COLOR"] = "1"
    return environment
  }

  static let executionPreamble = """
  You are running non-interactively in an empty scratch directory as a text-processing step. \
  Do not run shell commands, read other files, or modify anything: everything you need is in this message. \
  Reply with the final answer only.
  """

  static func organizePrompt(transcript: String, glossary: String) -> String {
    """
    \(MeetingPostProcessingPrompts.organizeSystemPrompt)
    \(executionPreamble)

    \(MeetingPostProcessingPrompts.organizeUserPrompt(transcript: transcript, glossary: glossary))
    """
  }

  static func analysisPrompt(transcript: String) -> String {
    """
    \(MeetingPostProcessingPrompts.analysisSystemPrompt)
    \(executionPreamble)
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

  static func tail(of text: String, maxLines: Int, maxCharacters: Int = 1_500) -> String {
    let lines = text
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let joined = lines.suffix(maxLines).joined(separator: " | ")
    if joined.isEmpty {
      return "no output"
    }
    return joined.count > maxCharacters ? "…" + String(joined.suffix(maxCharacters)) : joined
  }

  /// JSON Schema for `--output-schema`, mirroring the shape in `MeetingPostProcessingPrompts.analysisUserPrompt`.
  /// Structured outputs require every property to be listed in `required`; optional values are nullable.
  static let analysisOutputSchema: String = {
    func object(_ properties: [String: Any]) -> [String: Any] {
      [
        "type": "object",
        "additionalProperties": false,
        "required": properties.keys.sorted(),
        "properties": properties,
      ]
    }
    func array(_ items: [String: Any]) -> [String: Any] {
      ["type": "array", "items": items]
    }
    func enumeration(_ values: [String]) -> [String: Any] {
      ["type": "string", "enum": values]
    }
    let string: [String: Any] = ["type": "string"]
    let nullableString: [String: Any] = ["type": ["string", "null"]]
    let number: [String: Any] = ["type": "number"]
    let person = object([
      "id": string,
      "displayName": string,
      "aliases": array(string),
    ])

    let schema = object([
      "summary": string,
      "keyPoints": array(string),
      "actionItems": array(string),
      "decisions": array(object([
        "text": string,
        "status": enumeration(["candidate", "confirmed"]),
        "confidence": number,
        "relatedProjectID": nullableString,
        "evidence": nullableString,
      ])),
      "openLoops": array(object([
        "type": enumeration(["actionItem", "openQuestion", "followUp", "risk"]),
        "text": string,
        "owner": nullableString,
        "dueHint": nullableString,
        "status": enumeration(["open", "closed", "dropped"]),
        "relatedProjectID": nullableString,
        "evidence": nullableString,
      ])),
      "risks": array(object([
        "text": string,
        "confidence": number,
        "relatedProjectID": nullableString,
        "evidence": nullableString,
      ])),
      "participantPositions": array(object([
        "person": person,
        "label": string,
        "stance": string,
        "confidence": number,
        "evidence": nullableString,
      ])),
      "projectLinks": array(object([
        "project": object([
          "id": string,
          "title": string,
          "aliases": array(string),
        ]),
        "role": enumeration(["primary", "secondary", "mentioned"]),
        "status": enumeration(["unresolved", "confirmed", "rejected"]),
        "confidence": number,
        "evidence": nullableString,
      ])),
      "relatedPeople": array(person),
    ])

    let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }()
}

extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
