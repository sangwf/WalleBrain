import Foundation

public struct TermEntry: Identifiable, Sendable, Hashable {
  public var id: String { canonical }
  public let canonical: String
  public let aliases: [String]
  public let type: String?
  public let notes: String?

  public init(canonical: String, aliases: [String], type: String?, notes: String?) {
    self.canonical = canonical
    self.aliases = aliases
    self.type = type
    self.notes = notes
  }
}

public struct TermDictionary: Sendable, Hashable {
  public let title: String
  public let entries: [TermEntry]

  public init(title: String, entries: [TermEntry]) {
    self.title = title
    self.entries = entries
  }

  public var allTerms: [String] {
    Array(
      Set(
        entries.flatMap { entry in
          [entry.canonical] + entry.aliases
        }
      )
    ).sorted()
  }
}

public struct CompiledLanguageAssets: Sendable, Hashable {
  public let assetDataURL: URL
  public let languageModelURL: URL
  public let vocabularyURL: URL
}

public enum MeetingBlockKind: String, Codable, Sendable, Hashable, CaseIterable {
  case executiveSummary
  case organizedTranscript
  case keyPoint
  case actionItem
  case decision
  case risk
  case openQuestion
  case participantPosition
  case projectLink
  case transcriptSelection
}

public struct MeetingBlockAnchor: Codable, Sendable, Hashable {
  public let kind: MeetingBlockKind
  public let blockID: String?
  public let transcriptQuote: String?
  public let chunkIDs: [String]

  public init(
    kind: MeetingBlockKind,
    blockID: String? = nil,
    transcriptQuote: String? = nil,
    chunkIDs: [String] = []
  ) {
    self.kind = kind
    self.blockID = blockID
    self.transcriptQuote = transcriptQuote
    self.chunkIDs = chunkIDs
  }
}

public enum ReviewFeedbackType: String, Codable, Sendable, Hashable, CaseIterable {
  case factualError
  case omission
  case emphasis
  case attribution
  case style
  case invalidActionItem
  case promoteToDecision
  case projectLink
  case personLink
  case custom
}

public enum ReviewCommentStatus: String, Codable, Sendable, Hashable, CaseIterable {
  case pending
  case applied
  case rejected
}

public struct ReviewComment: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public let createdAt: Date
  public var anchor: MeetingBlockAnchor
  public var type: ReviewFeedbackType
  public var comment: String
  public var proposedText: String?
  public var targetProjectID: String?
  public var targetPersonID: String?
  public var status: ReviewCommentStatus

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    anchor: MeetingBlockAnchor,
    type: ReviewFeedbackType,
    comment: String,
    proposedText: String? = nil,
    targetProjectID: String? = nil,
    targetPersonID: String? = nil,
    status: ReviewCommentStatus = .pending
  ) {
    self.id = id
    self.createdAt = createdAt
    self.anchor = anchor
    self.type = type
    self.comment = comment
    self.proposedText = proposedText
    self.targetProjectID = targetProjectID
    self.targetPersonID = targetPersonID
    self.status = status
  }
}

public enum RevisionScope: String, Codable, Sendable, Hashable, CaseIterable {
  case block
  case note
  case projectMemory
}

public enum RevisionRequestStatus: String, Codable, Sendable, Hashable, CaseIterable {
  case pending
  case applied
  case rejected
}

public struct RevisionRequest: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public let createdAt: Date
  public var scope: RevisionScope
  public var anchor: MeetingBlockAnchor?
  public var instructions: String
  public var reviewCommentIDs: [UUID]
  public var status: RevisionRequestStatus

  public init(
    id: UUID = UUID(),
    createdAt: Date = Date(),
    scope: RevisionScope,
    anchor: MeetingBlockAnchor? = nil,
    instructions: String,
    reviewCommentIDs: [UUID] = [],
    status: RevisionRequestStatus = .pending
  ) {
    self.id = id
    self.createdAt = createdAt
    self.scope = scope
    self.anchor = anchor
    self.instructions = instructions
    self.reviewCommentIDs = reviewCommentIDs
    self.status = status
  }
}

public struct ProjectReference: Identifiable, Codable, Sendable, Hashable {
  public let id: String
  public var title: String
  public var aliases: [String]

  public init(id: String, title: String, aliases: [String] = []) {
    self.id = id
    self.title = title
    self.aliases = aliases
  }
}

public enum ProjectLinkRole: String, Codable, Sendable, Hashable, CaseIterable {
  case primary
  case secondary
  case mentioned
}

public enum ProjectLinkStatus: String, Codable, Sendable, Hashable, CaseIterable {
  case unresolved
  case confirmed
  case rejected
}

public struct MeetingProjectLink: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var project: ProjectReference
  public var role: ProjectLinkRole
  public var status: ProjectLinkStatus
  public var confidence: Double
  public var evidence: String?

  public init(
    id: UUID = UUID(),
    project: ProjectReference,
    role: ProjectLinkRole = .mentioned,
    status: ProjectLinkStatus = .unresolved,
    confidence: Double = 0.5,
    evidence: String? = nil
  ) {
    self.id = id
    self.project = project
    self.role = role
    self.status = status
    self.confidence = confidence
    self.evidence = evidence
  }
}

public struct PersonReference: Identifiable, Codable, Sendable, Hashable {
  public let id: String
  public var displayName: String
  public var aliases: [String]

  public init(id: String, displayName: String, aliases: [String] = []) {
    self.id = id
    self.displayName = displayName
    self.aliases = aliases
  }
}

public struct ParticipantPosition: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var person: PersonReference?
  public var label: String
  public var stance: String
  public var confidence: Double
  public var evidence: String?

  public init(
    id: UUID = UUID(),
    person: PersonReference? = nil,
    label: String,
    stance: String,
    confidence: Double = 0.5,
    evidence: String? = nil
  ) {
    self.id = id
    self.person = person
    self.label = label
    self.stance = stance
    self.confidence = confidence
    self.evidence = evidence
  }
}

public enum DecisionStatus: String, Codable, Sendable, Hashable, CaseIterable {
  case candidate
  case confirmed
}

public struct MeetingDecision: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var text: String
  public var status: DecisionStatus
  public var confidence: Double
  public var relatedProjectID: String?
  public var evidence: String?

  public init(
    id: UUID = UUID(),
    text: String,
    status: DecisionStatus = .candidate,
    confidence: Double = 0.5,
    relatedProjectID: String? = nil,
    evidence: String? = nil
  ) {
    self.id = id
    self.text = text
    self.status = status
    self.confidence = confidence
    self.relatedProjectID = relatedProjectID
    self.evidence = evidence
  }
}

public struct MeetingRisk: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var text: String
  public var confidence: Double
  public var relatedProjectID: String?
  public var evidence: String?

  public init(
    id: UUID = UUID(),
    text: String,
    confidence: Double = 0.5,
    relatedProjectID: String? = nil,
    evidence: String? = nil
  ) {
    self.id = id
    self.text = text
    self.confidence = confidence
    self.relatedProjectID = relatedProjectID
    self.evidence = evidence
  }
}

public enum OpenLoopType: String, Codable, Sendable, Hashable, CaseIterable {
  case actionItem
  case openQuestion
  case followUp
  case risk
}

public enum OpenLoopStatus: String, Codable, Sendable, Hashable, CaseIterable {
  case open
  case closed
  case dropped
}

public struct MeetingOpenLoop: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var type: OpenLoopType
  public var text: String
  public var owner: String?
  public var dueHint: String?
  public var status: OpenLoopStatus
  public var relatedProjectID: String?
  public var evidence: String?

  public init(
    id: UUID = UUID(),
    type: OpenLoopType,
    text: String,
    owner: String? = nil,
    dueHint: String? = nil,
    status: OpenLoopStatus = .open,
    relatedProjectID: String? = nil,
    evidence: String? = nil
  ) {
    self.id = id
    self.type = type
    self.text = text
    self.owner = owner
    self.dueHint = dueHint
    self.status = status
    self.relatedProjectID = relatedProjectID
    self.evidence = evidence
  }
}

public struct DeerAPIResult: Sendable, Hashable {
  public let provider: String
  public let model: String
  public let summary: String
  public let organizedTranscript: String
  public let keyPoints: [String]
  public let actionItems: [String]
  public let decisions: [MeetingDecision]
  public let openLoops: [MeetingOpenLoop]
  public let risks: [MeetingRisk]
  public let participantPositions: [ParticipantPosition]
  public let projectLinks: [MeetingProjectLink]
  public let relatedPeople: [PersonReference]

  public init(
    provider: String,
    model: String,
    summary: String,
    organizedTranscript: String,
    keyPoints: [String],
    actionItems: [String],
    decisions: [MeetingDecision] = [],
    openLoops: [MeetingOpenLoop] = [],
    risks: [MeetingRisk] = [],
    participantPositions: [ParticipantPosition] = [],
    projectLinks: [MeetingProjectLink] = [],
    relatedPeople: [PersonReference] = []
  ) {
    self.provider = provider
    self.model = model
    self.summary = summary
    self.organizedTranscript = organizedTranscript
    self.keyPoints = keyPoints
    self.actionItems = actionItems
    self.decisions = decisions
    self.openLoops = openLoops
    self.risks = risks
    self.participantPositions = participantPositions
    self.projectLinks = projectLinks
    self.relatedPeople = relatedPeople
  }
}

public struct SummaryRevisionResult: Sendable, Hashable {
  public let provider: String
  public let model: String
  public let summary: String

  public init(provider: String, model: String, summary: String) {
    self.provider = provider
    self.model = model
    self.summary = summary
  }
}

public enum MeetingMode: String, Codable, Sendable, Hashable, CaseIterable {
  case normal
  case important
}

public enum MeetingStatus: String, Codable, Sendable, Hashable {
  case idle
  case preparing
  case recording
  case processing
  case exported
  case failed
}

public struct TranscriptChunk: Codable, Sendable, Hashable, Identifiable {
  public let id: String
  public let startSeconds: Double
  public let durationSeconds: Double
  public let text: String

  public init(id: String, startSeconds: Double, durationSeconds: Double, text: String) {
    self.id = id
    self.startSeconds = startSeconds
    self.durationSeconds = durationSeconds
    self.text = text
  }
}

public struct AudioInputDevice: Identifiable, Codable, Sendable, Hashable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct TranscriptCorrection: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var wrong: String
  public var correct: String
  public var type: String?

  public init(id: UUID = UUID(), wrong: String, correct: String, type: String? = nil) {
    self.id = id
    self.wrong = wrong
    self.correct = correct
    self.type = type
  }
}

public struct CorrectionMemoryEntry: Identifiable, Codable, Sendable, Hashable {
  public let id: UUID
  public var wrong: String
  public var correct: String
  public var type: String?
  public var count: Int
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    wrong: String,
    correct: String,
    type: String? = nil,
    count: Int = 1,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.wrong = wrong
    self.correct = correct
    self.type = type
    self.count = count
    self.updatedAt = updatedAt
  }
}

public struct NativeMeetingSession: Codable, Sendable, Hashable, Identifiable {
  public let id: UUID
  public var title: String
  public var mode: MeetingMode
  public var status: MeetingStatus
  public let startedAt: Date
  public var endedAt: Date?
  public var selectedInput: AudioInputDevice?
  public var dictionaryPath: String
  public var audioFilePath: String
  public var sessionJSONPath: String
  public var sessionMarkdownPath: String
  public var exportedNotePath: String?
  public var provider: String?
  public var model: String?
  public var liveTranscript: String
  public var correctedTranscript: String?
  public var transcriptChunks: [TranscriptChunk]
  public var sessionCorrections: [TranscriptCorrection]?
  public var summary: String?
  public var organizedTranscript: String?
  public var keyPoints: [String]
  public var actionItems: [String]
  public var decisions: [MeetingDecision]?
  public var openLoops: [MeetingOpenLoop]?
  public var risks: [MeetingRisk]?
  public var participantPositions: [ParticipantPosition]?
  public var projectLinks: [MeetingProjectLink]?
  public var relatedPeople: [PersonReference]?
  public var reviewComments: [ReviewComment]?
  public var revisionRequests: [RevisionRequest]?
  public var errorMessage: String?

  public init(
    id: UUID = UUID(),
    title: String,
    mode: MeetingMode,
    status: MeetingStatus,
    startedAt: Date,
    endedAt: Date? = nil,
    selectedInput: AudioInputDevice? = nil,
    dictionaryPath: String,
    audioFilePath: String,
    sessionJSONPath: String,
    sessionMarkdownPath: String,
    exportedNotePath: String? = nil,
    provider: String? = nil,
    model: String? = nil,
    liveTranscript: String = "",
    correctedTranscript: String? = nil,
    transcriptChunks: [TranscriptChunk] = [],
    sessionCorrections: [TranscriptCorrection]? = nil,
    summary: String? = nil,
    organizedTranscript: String? = nil,
    keyPoints: [String] = [],
    actionItems: [String] = [],
    decisions: [MeetingDecision]? = nil,
    openLoops: [MeetingOpenLoop]? = nil,
    risks: [MeetingRisk]? = nil,
    participantPositions: [ParticipantPosition]? = nil,
    projectLinks: [MeetingProjectLink]? = nil,
    relatedPeople: [PersonReference]? = nil,
    reviewComments: [ReviewComment]? = nil,
    revisionRequests: [RevisionRequest]? = nil,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.title = title
    self.mode = mode
    self.status = status
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.selectedInput = selectedInput
    self.dictionaryPath = dictionaryPath
    self.audioFilePath = audioFilePath
    self.sessionJSONPath = sessionJSONPath
    self.sessionMarkdownPath = sessionMarkdownPath
    self.exportedNotePath = exportedNotePath
    self.provider = provider
    self.model = model
    self.liveTranscript = liveTranscript
    self.correctedTranscript = correctedTranscript
    self.transcriptChunks = transcriptChunks
    self.sessionCorrections = sessionCorrections
    self.summary = summary
    self.organizedTranscript = organizedTranscript
    self.keyPoints = keyPoints
    self.actionItems = actionItems
    self.decisions = decisions
    self.openLoops = openLoops
    self.risks = risks
    self.participantPositions = participantPositions
    self.projectLinks = projectLinks
    self.relatedPeople = relatedPeople
    self.reviewComments = reviewComments
    self.revisionRequests = revisionRequests
    self.errorMessage = errorMessage
  }
}

public struct NativeMeetingNote: Sendable, Hashable {
  public let title: String
  public let startedAt: Date
  public let endedAt: Date?
  public let transcript: String
  public let liveTranscript: String
  public let summary: String
  public let organizedTranscript: String
  public let keyPoints: [String]
  public let actionItems: [String]
  public let decisions: [MeetingDecision]
  public let openLoops: [MeetingOpenLoop]
  public let risks: [MeetingRisk]
  public let participantPositions: [ParticipantPosition]
  public let projectLinks: [MeetingProjectLink]
  public let relatedPeople: [PersonReference]
  public let dictionaryPath: String
  public let audioFilePath: String
  public let provider: String
  public let model: String

  public init(
    title: String,
    startedAt: Date,
    endedAt: Date?,
    transcript: String,
    liveTranscript: String,
    summary: String,
    organizedTranscript: String,
    keyPoints: [String],
    actionItems: [String],
    decisions: [MeetingDecision] = [],
    openLoops: [MeetingOpenLoop] = [],
    risks: [MeetingRisk] = [],
    participantPositions: [ParticipantPosition] = [],
    projectLinks: [MeetingProjectLink] = [],
    relatedPeople: [PersonReference] = [],
    dictionaryPath: String,
    audioFilePath: String,
    provider: String,
    model: String
  ) {
    self.title = title
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.transcript = transcript
    self.liveTranscript = liveTranscript
    self.summary = summary
    self.organizedTranscript = organizedTranscript
    self.keyPoints = keyPoints
    self.actionItems = actionItems
    self.decisions = decisions
    self.openLoops = openLoops
    self.risks = risks
    self.participantPositions = participantPositions
    self.projectLinks = projectLinks
    self.relatedPeople = relatedPeople
    self.dictionaryPath = dictionaryPath
    self.audioFilePath = audioFilePath
    self.provider = provider
    self.model = model
  }
}

public struct FixtureHarnessResult: Sendable, Hashable {
  public let dictionaryPath: URL
  public let assets: CompiledLanguageAssets
  public let notePath: URL
  public let deerAPI: DeerAPIResult
}

public enum WalleBrainError: Error, LocalizedError {
  case missingEnvironment(String)
  case invalidResponse(String)
  case invalidModelPayload
  case dictionaryMissingEntry(String)

  public var errorDescription: String? {
    switch self {
    case let .missingEnvironment(name):
      return "Missing required environment variable: \(name)"
    case let .invalidResponse(message):
      return "Invalid response: \(message)"
    case .invalidModelPayload:
      return "Model response did not contain valid JSON."
    case let .dictionaryMissingEntry(message):
      return "Dictionary parsing error: \(message)"
    }
  }
}
