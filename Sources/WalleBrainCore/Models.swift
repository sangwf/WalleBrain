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

public struct DeerAPIResult: Sendable, Hashable {
  public let provider: String
  public let model: String
  public let summary: String
  public let organizedTranscript: String
  public let keyPoints: [String]
  public let actionItems: [String]
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
  public var transcriptChunks: [TranscriptChunk]
  public var summary: String?
  public var organizedTranscript: String?
  public var keyPoints: [String]
  public var actionItems: [String]
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
    transcriptChunks: [TranscriptChunk] = [],
    summary: String? = nil,
    organizedTranscript: String? = nil,
    keyPoints: [String] = [],
    actionItems: [String] = [],
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
    self.transcriptChunks = transcriptChunks
    self.summary = summary
    self.organizedTranscript = organizedTranscript
    self.keyPoints = keyPoints
    self.actionItems = actionItems
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
  public let dictionaryPath: String
  public let audioFilePath: String
  public let provider: String
  public let model: String
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
