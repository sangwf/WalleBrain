import Foundation
import Testing
@testable import WalleBrainCore

struct MeetingMemoryModelsTests {
  @Test
  func decodesLegacySessionPayloadWithoutNewMemoryFields() throws {
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

    let session = try decoder.decode(NativeMeetingSession.self, from: Data(json.utf8))

    #expect(session.title == "Legacy Session")
    #expect(session.decisions == nil)
    #expect(session.openLoops == nil)
    #expect(session.projectLinks == nil)
    #expect(session.reviewComments == nil)
  }

  @Test
  func preservesMeetingMemoryFieldsAcrossRoundTrip() throws {
    let session = NativeMeetingSession(
      title: "Project Atlas Sync",
      mode: .important,
      status: .exported,
      startedAt: Date(timeIntervalSince1970: 200),
      endedAt: Date(timeIntervalSince1970: 300),
      selectedInput: AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro麦克风"),
      dictionaryPath: "/tmp/dictionary.md",
      audioFilePath: "/tmp/audio.caf",
      sessionJSONPath: "/tmp/session.json",
      sessionMarkdownPath: "/tmp/session.md",
      liveTranscript: "我们决定下周上线。",
      correctedTranscript: "我们决定下周上线。",
      summary: "讨论了 Atlas 的上线节奏。",
      organizedTranscript: "A: 我们决定下周上线。",
      keyPoints: ["Atlas 上线时间提前。"],
      actionItems: ["确认发布 checklist。"],
      decisions: [
        MeetingDecision(
          text: "Atlas 下周上线",
          status: .confirmed,
          confidence: 0.95,
          relatedProjectID: "project-atlas",
          evidence: "我们决定下周上线。"
        ),
      ],
      openLoops: [
        MeetingOpenLoop(
          type: .followUp,
          text: "确认发布 checklist",
          owner: "产品",
          dueHint: "下周上线前",
          relatedProjectID: "project-atlas"
        ),
      ],
      risks: [
        MeetingRisk(
          text: "发布 checklist 还未对齐",
          confidence: 0.8,
          relatedProjectID: "project-atlas"
        ),
      ],
      participantPositions: [
        ParticipantPosition(
          person: PersonReference(id: "alice-chen", displayName: "Alice Chen"),
          label: "Alice Chen",
          stance: "倾向于按原计划推进",
          confidence: 0.7
        ),
      ],
      projectLinks: [
        MeetingProjectLink(
          project: ProjectReference(id: "project-atlas", title: "Project Atlas"),
          role: .primary,
          status: .confirmed,
          confidence: 0.93,
          evidence: "Atlas 上线时间提前。"
        ),
      ],
      relatedPeople: [
        PersonReference(id: "alice-chen", displayName: "Alice Chen"),
      ],
      reviewComments: [
        ReviewComment(
          anchor: MeetingBlockAnchor(kind: .executiveSummary),
          type: .omission,
          comment: "漏掉了上线时间提前这件事。"
        ),
      ],
      revisionRequests: [
        RevisionRequest(
          scope: .block,
          anchor: MeetingBlockAnchor(kind: .executiveSummary),
          instructions: "补充上线时间变化。"
        ),
      ]
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(session)
    let decoded = try decoder.decode(NativeMeetingSession.self, from: data)

    #expect(decoded.decisions?.first?.text == "Atlas 下周上线")
    #expect(decoded.openLoops?.first?.type == .followUp)
    #expect(decoded.risks?.first?.relatedProjectID == "project-atlas")
    #expect(decoded.projectLinks?.first?.project.title == "Project Atlas")
    #expect(decoded.relatedPeople?.first?.displayName == "Alice Chen")
    #expect(decoded.reviewComments?.first?.type == .omission)
    #expect(decoded.revisionRequests?.first?.scope == .block)
  }
}
