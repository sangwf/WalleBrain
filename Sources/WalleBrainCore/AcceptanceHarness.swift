import Foundation

public struct StructuredNoteFixtureSuite: Codable, Sendable, Hashable {
  public let fixtures: [StructuredNoteFixture]
}

public struct StructuredNoteFixture: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let title: String
  public let transcript: String
  public let expectations: StructuredNoteExpectations
}

public struct StructuredNoteExpectations: Codable, Sendable, Hashable {
  public let decisionContains: [String]
  public let actionItemContains: [String]
  public let preserveTentativeTerms: [String]
  public let forbidDecisions: Bool
  public let forbidActionItems: Bool
  public let projectStatusByID: [String: String]
}

public struct FixtureEvaluationCase: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let passed: Bool
  public let errors: [String]
  public let diagnostics: FixtureEvaluationDiagnostics?

  public init(
    id: String,
    passed: Bool,
    errors: [String],
    diagnostics: FixtureEvaluationDiagnostics? = nil
  ) {
    self.id = id
    self.passed = passed
    self.errors = errors
    self.diagnostics = diagnostics
  }
}

public struct FixtureEvaluationSummary: Codable, Sendable, Hashable {
  public let passed: Bool
  public let cases: [FixtureEvaluationCase]

  public init(passed: Bool, cases: [FixtureEvaluationCase]) {
    self.passed = passed
    self.cases = cases
  }
}

public struct FixtureEvaluationDiagnostics: Codable, Sendable, Hashable {
  public let summary: String
  public let keyPoints: [String]
  public let actionItems: [String]
  public let decisions: [String]
  public let openLoops: [String]
  public let projectLinks: [String]

  public init(
    summary: String,
    keyPoints: [String],
    actionItems: [String],
    decisions: [String],
    openLoops: [String],
    projectLinks: [String]
  ) {
    self.summary = summary
    self.keyPoints = keyPoints
    self.actionItems = actionItems
    self.decisions = decisions
    self.openLoops = openLoops
    self.projectLinks = projectLinks
  }
}

public enum AcceptanceHarnessError: Error, LocalizedError {
  case fixtureNotFound(String)
  case fixtureTimeout(String)

  public var errorDescription: String? {
    switch self {
    case let .fixtureNotFound(id):
      return "No deterministic candidate is defined for fixture: \(id)"
    case let .fixtureTimeout(id):
      return "Fixture evaluation timed out: \(id)"
    }
  }
}

public enum AcceptanceHarness {
  public static func loadStructuredNoteFixtureSuite(baseDirectory: URL) throws -> StructuredNoteFixtureSuite {
    let url = baseDirectory.appending(path: "fixtures/acceptance/structured_note_fixtures.json", directoryHint: .notDirectory)
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(StructuredNoteFixtureSuite.self, from: data)
  }

  public static func evaluateFixtureSuite(_ suite: StructuredNoteFixtureSuite) throws -> FixtureEvaluationSummary {
    let cases = try suite.fixtures.map { fixture in
      let result = try deterministicCandidate(for: fixture)
      let errors = evaluate(result: result, against: fixture.expectations)
      return FixtureEvaluationCase(
        id: fixture.id,
        passed: errors.isEmpty,
        errors: errors,
        diagnostics: diagnostics(from: result)
      )
    }
    return FixtureEvaluationSummary(
      passed: cases.allSatisfy(\.passed),
      cases: cases
    )
  }

  public static func evaluateFixtureSuiteReal(
    _ suite: StructuredNoteFixtureSuite,
    dictionary: TermDictionary,
    client: DeerAPIClient,
    perFixtureTimeoutSeconds: Double = 45,
    maxAttempts: Int = 2,
    retryDelaySeconds: Double = 2
  ) async throws -> FixtureEvaluationSummary {
    var cases: [FixtureEvaluationCase] = []
    cases.reserveCapacity(suite.fixtures.count)

    for fixture in suite.fixtures {
      do {
        let result = try await retrying(
          attempts: maxAttempts,
          retryDelaySeconds: retryDelaySeconds
        ) {
          try await withTimeout(seconds: perFixtureTimeoutSeconds) {
            try await client.summarizeFixtureTranscript(fixture.transcript, dictionary: dictionary)
          } onTimeout: {
            AcceptanceHarnessError.fixtureTimeout(fixture.id)
          }
        }
        let errors = evaluate(result: result, against: fixture.expectations)
        cases.append(
          FixtureEvaluationCase(
            id: fixture.id,
            passed: errors.isEmpty,
            errors: errors,
            diagnostics: diagnostics(from: result)
          )
        )
      } catch {
        cases.append(
          FixtureEvaluationCase(
            id: fixture.id,
            passed: false,
            errors: ["fixture evaluation failed: \(error.localizedDescription)"]
          )
        )
      }
    }

    return FixtureEvaluationSummary(
      passed: cases.allSatisfy(\.passed),
      cases: cases
    )
  }

  public static func decodeLegacySessionCheck() throws -> Bool {
    let json = """
    {
      "actionItems": [],
      "audioFilePath": "/tmp/audio.caf",
      "dictionaryPath": "/tmp/dictionary.md",
      "id": "11111111-1111-1111-1111-111111111111",
      "keyPoints": [],
      "liveTranscript": "hello",
      "mode": "normal",
      "sessionJSONPath": "/tmp/session.json",
      "sessionMarkdownPath": "/tmp/session.md",
      "startedAt": "1970-01-01T00:01:40Z",
      "status": "recording",
      "title": "Legacy Session",
      "transcriptChunks": []
    }
    """

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    _ = try decoder.decode(NativeMeetingSession.self, from: Data(json.utf8))
    return true
  }

  public static func reviewRoundTripCheck() -> (passed: Bool, before: String, after: String) {
    let anchor = MeetingBlockAnchor(kind: .executiveSummary)
    let comment = ReviewComment(
      anchor: anchor,
      type: .omission,
      comment: "补充 Atlas 下周上线。",
      proposedText: "Atlas 项目确认下周上线，发布 checklist 仍需补齐。"
    )
    let request = RevisionRequest(
      scope: .block,
      anchor: anchor,
      instructions: "只更新 summary，补充上线信息。",
      reviewCommentIDs: [comment.id]
    )

    let session = NativeMeetingSession(
      title: "Atlas Sync",
      mode: .important,
      status: .exported,
      startedAt: Date(timeIntervalSince1970: 300),
      dictionaryPath: "/tmp/dictionary.md",
      audioFilePath: "/tmp/audio.caf",
      sessionJSONPath: "/tmp/session.json",
      sessionMarkdownPath: "/tmp/session.md",
      liveTranscript: "我们决定下周上线。",
      correctedTranscript: "我们决定下周上线。",
      summary: "讨论了发布节奏。",
      organizedTranscript: "A: 我们决定下周上线。",
      keyPoints: ["讨论了发布节奏。"],
      actionItems: ["补齐 checklist。"],
      reviewComments: [comment],
      revisionRequests: [request]
    )

    let updated = applyRevisionRequest(request, to: session)
    let passed = updated.summary != session.summary
      && updated.organizedTranscript == session.organizedTranscript
      && updated.liveTranscript == session.liveTranscript
    return (passed, session.summary ?? "", updated.summary ?? "")
  }

  public static func requiredStructuredSectionsPresent(in noteMarkdown: String) -> [String: Bool] {
    let requiredSections = [
      "## Summary",
      "## Organized Transcript",
      "## Key Points",
      "## Decisions",
      "## Action Items",
      "## Open Loops",
      "## Risks",
      "## Related Projects",
      "## Related People",
      "## Participant Positions",
      "## Live Transcript",
      "## Final Transcript",
    ]

    return Dictionary(uniqueKeysWithValues: requiredSections.map { section in
      (section, noteMarkdown.contains(section))
    })
  }

  public static func requiredStructuredKeysPresent(in sessionJSONData: Data) throws -> [String: Bool] {
    let payload = try JSONSerialization.jsonObject(with: sessionJSONData) as? [String: Any] ?? [:]
    let keys = [
      "summary",
      "organizedTranscript",
      "keyPoints",
      "actionItems",
      "decisions",
      "openLoops",
      "risks",
      "projectLinks",
    ]
    return Dictionary(uniqueKeysWithValues: keys.map { ($0, payload.keys.contains($0)) })
  }

  private static func deterministicCandidate(for fixture: StructuredNoteFixture) throws -> DeerAPIResult {
    switch fixture.id {
    case "decision-action-project":
      return DeerAPIResult(
        provider: "deterministic",
        model: "fixture",
        summary: "会议确认 Atlas 下周上线，并要求补齐发布 checklist。",
        organizedTranscript: "A: 我们决定 Atlas 下周上线。\nB: 发布 checklist 需要本周补齐。",
        keyPoints: ["Atlas 下周上线。", "发布 checklist 仍需补齐。"],
        actionItems: ["本周补齐发布 checklist。"],
        decisions: [
          MeetingDecision(
            text: "Atlas 下周上线",
            status: .confirmed,
            confidence: 0.95,
            relatedProjectID: "project-atlas"
          ),
        ],
        openLoops: [
          MeetingOpenLoop(
            type: .actionItem,
            text: "本周补齐发布 checklist",
            owner: "团队",
            relatedProjectID: "project-atlas"
          ),
        ],
        projectLinks: [
          MeetingProjectLink(
            project: ProjectReference(id: "project-atlas", title: "Project Atlas"),
            role: .primary,
            status: .confirmed,
            confidence: 0.95
          ),
        ]
      )
    case "tentative-no-hallucinated-action":
      return DeerAPIResult(
        provider: "deterministic",
        model: "fixture",
        summary: "大家提到可能下个月再看预算，但目前没有形成确定动作。",
        organizedTranscript: "A: 预算可能下个月再看。\nB: 先观察一下。",
        keyPoints: ["预算可能下个月再看。", "目前先观察一下。"],
        actionItems: [],
        openLoops: [
          MeetingOpenLoop(type: .openQuestion, text: "预算是否下个月再推进")
        ]
      )
    case "no-action-background-only":
      return DeerAPIResult(
        provider: "deterministic",
        model: "fixture",
        summary: "本次主要是背景交流，没有形成明确行动项。",
        organizedTranscript: "A: 先交流一下背景。\nB: 目前没有明确 follow-up。",
        keyPoints: ["进行了背景信息同步。"],
        actionItems: []
      )
    case "unresolved-project-link":
      return DeerAPIResult(
        provider: "deterministic",
        model: "fixture",
        summary: "会议提到了 Apollo，但当前无法确认其是否对应已有项目。",
        organizedTranscript: "A: Apollo 这个事情之后再看。\nB: 先别并到现有项目。",
        keyPoints: ["提到了 Apollo，但未确认归属。"],
        actionItems: [],
        projectLinks: [
          MeetingProjectLink(
            project: ProjectReference(id: "apollo", title: "Apollo"),
            role: .mentioned,
            status: .unresolved,
            confidence: 0.55
          ),
        ]
      )
    default:
      throw AcceptanceHarnessError.fixtureNotFound(fixture.id)
    }
  }

  private static func evaluate(result: DeerAPIResult, against expectations: StructuredNoteExpectations) -> [String] {
    var errors: [String] = []
    let decisionText = result.decisions.map(\.text).joined(separator: "\n")
    let actionText = result.actionItems.joined(separator: "\n")
    let projectStatus = Dictionary(uniqueKeysWithValues: result.projectLinks.flatMap { link in
      let tokens = Set([
        normalizedProjectKey(link.project.id),
        normalizedProjectKey(link.project.title),
      ] + link.project.aliases.map(normalizedProjectKey))
      return tokens.map { ($0, link.status.rawValue) }
    })
    let tentativeCorpus = ([result.summary] + result.keyPoints).joined(separator: "\n")

    for snippet in expectations.decisionContains where !decisionText.contains(snippet) {
      errors.append("missing decision snippet: \(snippet)")
    }
    for snippet in expectations.actionItemContains where !actionText.contains(snippet) {
      errors.append("missing action item snippet: \(snippet)")
    }
    for term in expectations.preserveTentativeTerms where !tentativeCorpus.contains(term) {
      errors.append("missing tentative term: \(term)")
    }
    if expectations.forbidDecisions && !result.decisions.isEmpty {
      errors.append("unexpected decisions present")
    }
    if expectations.forbidActionItems && !result.actionItems.isEmpty {
      errors.append("unexpected action items present")
    }
    for (projectID, expectedStatus) in expectations.projectStatusByID {
      if projectStatus[normalizedProjectKey(projectID)] != expectedStatus {
        errors.append("project \(projectID) status mismatch")
      }
    }

    return errors
  }

  private static func diagnostics(from result: DeerAPIResult) -> FixtureEvaluationDiagnostics {
    FixtureEvaluationDiagnostics(
      summary: result.summary,
      keyPoints: result.keyPoints,
      actionItems: result.actionItems,
      decisions: result.decisions.map(\.text),
      openLoops: result.openLoops.map { "[\($0.type.rawValue)] \($0.text)" },
      projectLinks: result.projectLinks.map {
        "\($0.project.id)|\($0.project.title)|\($0.status.rawValue)|\($0.role.rawValue)"
      }
    )
  }

  private static func normalizedProjectKey(_ raw: String) -> String {
    raw
      .lowercased()
      .replacingOccurrences(of: "project-", with: "")
      .replacingOccurrences(of: "_", with: "-")
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
      .filter { !$0.isEmpty }
      .joined(separator: "-")
  }

  private static func applyRevisionRequest(
    _ request: RevisionRequest,
    to session: NativeMeetingSession
  ) -> NativeMeetingSession {
    var updated = session
    guard request.scope == .block else {
      return updated
    }
    guard request.anchor?.kind == .executiveSummary else {
      return updated
    }
    let candidateText = (session.reviewComments ?? [])
      .filter { request.reviewCommentIDs.contains($0.id) }
      .compactMap(\.proposedText)
      .first

    if let candidateText, !candidateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      updated.summary = candidateText
    } else {
      updated.summary = request.instructions
    }
    return updated
  }

  private static func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T,
    onTimeout: @escaping @Sendable () -> Error
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(seconds))
        throw onTimeout()
      }

      let result = try await group.next()!
      group.cancelAll()
      return result
    }
  }

  static func retrying<T: Sendable>(
    attempts: Int,
    retryDelaySeconds: Double,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    precondition(attempts > 0, "attempts must be greater than zero")

    var lastError: Error?
    for attempt in 1...attempts {
      do {
        return try await operation()
      } catch {
        lastError = error
        guard attempt < attempts else {
          throw error
        }

        if retryDelaySeconds > 0 {
          try await Task.sleep(for: .seconds(retryDelaySeconds))
        }
      }
    }

    throw lastError ?? AcceptanceHarnessError.fixtureTimeout("unknown")
  }
}
