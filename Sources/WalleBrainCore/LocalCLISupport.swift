import Foundation

public enum LocalCLIError: Error, LocalizedError, Sendable, Equatable {
  case executableNotFound(tool: String, searched: [String], installHint: String)
  case executableUnusable(tool: String, details: [String], installHint: String)
  case notAuthenticated(tool: String, details: String)
  case processFailed(tool: String, exitCode: Int32, details: String)
  case timedOut(seconds: Int)
  case emptyOutput(tool: String)

  /// The tool cannot run at all (missing, broken, or logged out), so retrying it for later stages is pointless.
  public var isUnavailable: Bool {
    switch self {
    case .executableNotFound, .executableUnusable, .notAuthenticated:
      return true
    case .processFailed, .timedOut, .emptyOutput:
      return false
    }
  }

  public var errorDescription: String? {
    switch self {
    case let .executableNotFound(tool, searched, installHint):
      return "\(tool) not found (searched \(searched.joined(separator: ", "))). \(installHint)"
    case let .executableUnusable(tool, details, installHint):
      return "\(tool) is installed but not runnable: \(details.joined(separator: "; ")). \(installHint)"
    case let .notAuthenticated(tool, details):
      return "\(tool) is not logged in: \(details)"
    case let .processFailed(tool, exitCode, details):
      return "\(tool) exited with status \(exitCode): \(details)"
    case let .timedOut(seconds):
      return "Local CLI timed out after \(seconds)s."
    case let .emptyOutput(tool):
      return "\(tool) returned no final message."
    }
  }
}

public struct LocalCLIExecutable: Sendable, Equatable {
  public let path: String
  public let version: String
}

public struct LocalCLIOptions: Sendable, Equatable {
  public var executablePath: String?
  /// `--model` override; nil uses the CLI's own default model.
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

/// A fresh temporary directory per call: `workspace/` holds only the text the CLI may see and is its working
/// root; `io/` holds schema and output files outside that root.
struct LocalCLIWorkspace {
  let root: URL
  let workspace: URL
  let io: URL

  static func make(files: [String: String]) throws -> LocalCLIWorkspace {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appending(path: "WalleBrainCLI-\(UUID().uuidString)", directoryHint: .isDirectory)
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    let io = root.appending(path: "io", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: io, withIntermediateDirectories: true)
    for (name, contents) in files {
      try Data(contents.utf8).write(to: workspace.appending(path: name, directoryHint: .notDirectory))
    }
    return LocalCLIWorkspace(root: root, workspace: workspace, io: io)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

enum LocalCLISupport {
  /// Returns the first candidate binary whose `--version` output names the tool.
  static func resolveExecutable(
    resolver: CLIExecutableResolver,
    runner: any CLIProcessRunning,
    environment: [String: String],
    timeout: Duration
  ) async throws -> LocalCLIExecutable {
    let tool = resolver.tool
    let candidates = resolver.executableCandidates()
    guard !candidates.isEmpty else {
      throw LocalCLIError.executableNotFound(
        tool: tool.displayName,
        searched: resolver.searchLocations(),
        installHint: tool.installHint
      )
    }

    var failures: [String] = []
    for candidate in candidates {
      try Task.checkCancellation()
      do {
        let output = try await runner.run(
          CLIProcessInvocation(
            executableURL: URL(fileURLWithPath: candidate),
            arguments: ["--version"],
            environment: makeProcessEnvironment(
              base: environment,
              executablePath: candidate,
              searchDirectories: resolver.fallbackSearchDirectories
            ),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout
          )
        )
        let version = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.exitCode == 0, version.lowercased().contains(tool.binaryName) {
          return LocalCLIExecutable(path: candidate, version: version)
        }
        failures.append("\(candidate): \(tail(of: output.standardError.isEmpty ? output.standardOutput : output.standardError, maxLines: 2))")
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        failures.append("\(candidate): \(error.localizedDescription)")
      }
    }

    throw LocalCLIError.executableUnusable(tool: tool.displayName, details: failures, installHint: tool.installHint)
  }

  /// The GUI app's `PATH` usually lacks Homebrew and `~/.local/bin` (and npm wrappers need `node`), so put the
  /// binary's own directory and the usual install locations on `PATH`.
  static func makeProcessEnvironment(
    base: [String: String],
    executablePath: String,
    searchDirectories: [String]
  ) -> [String: String] {
    var environment = base
    var directories = [URL(fileURLWithPath: executablePath).deletingLastPathComponent().path(percentEncoded: false)]
    directories += (base["PATH"] ?? "").split(separator: ":").map(String.init)
    directories += searchDirectories
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

  /// A failed run caused by missing or expired credentials: the tier cannot work until the user logs in again.
  static func failure(tool: LocalCLITool, exitCode: Int32, details: String, loginHint: String) -> LocalCLIError {
    let lowered = details.lowercased()
    let authenticationMarkers = [
      "not logged in", "/login", "401 unauthorized", "missing bearer", "invalid api key",
      "authentication_error", "oauth token has expired",
    ]
    if authenticationMarkers.contains(where: lowered.contains) {
      return .notAuthenticated(tool: tool.displayName, details: "\(details) \(loginHint)")
    }
    return .processFailed(tool: tool.displayName, exitCode: exitCode, details: details)
  }

  /// Validates an organized transcript the same way `LLMChatClient` does before accepting it.
  static func acceptOrganizedTranscript(
    _ text: String,
    sourceTranscript: String,
    tool: LocalCLITool
  ) throws -> String {
    let organizedTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !organizedTranscript.isEmpty else {
      throw LocalCLIError.emptyOutput(tool: tool.displayName)
    }
    try OrganizedTranscriptQualityValidator.validate(
      organizedTranscript: organizedTranscript,
      sourceTranscript: sourceTranscript
    )
    return organizedTranscript
  }

  /// JSON Schema for structured analysis output, mirroring the shape in
  /// `MeetingPostProcessingPrompts.analysisUserPrompt`. Structured outputs require every property to be listed
  /// in `required`; optional values are nullable.
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

    let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }()
}

extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
