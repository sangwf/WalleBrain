import Foundation
import Testing
@testable import WalleBrainCore

struct MeetingPostProcessorTests {
  @Test
  func preservesOrganizedTranscriptWhenAnalysisFails() async throws {
    let fixture = try await makeFixture()
    let client = FakePostProcessingClient(
      organizedTranscript: fixture.organizedTranscript,
      analysisResult: .failure(.analysisFailed)
    )
    let processor = MeetingPostProcessor(paths: fixture.paths, client: client)

    let result = try await processor.process(fixture.session)

    #expect(result.status == .organized)
    #expect(result.liveTranscript == fixture.sourceTranscript)
    #expect(result.organizedTranscript == fixture.organizedTranscript)
    #expect(result.errorMessage?.contains("Structured analysis pending") == true)
    #expect(result.summary?.contains("整理稿已生成") == true)

    let persisted = try await MeetingSessionStore(paths: fixture.paths).listSessions(limit: 1).first
    #expect(persisted?.status == .organized)
    #expect(persisted?.organizedTranscript == fixture.organizedTranscript)
    #expect(FileManager.default.fileExists(atPath: result.exportedNotePath ?? ""))
  }

  @Test
  func exportsStructuredResultAfterOrganizedCheckpoint() async throws {
    let fixture = try await makeFixture()
    let analysis = LLMPostProcessingResult(
      provider: "fixture",
      model: "fixture-pro",
      summary: "会议讨论了神策的AI增长战略和融资安排。",
      organizedTranscript: fixture.organizedTranscript,
      keyPoints: ["AI增长团队", "融资安排"],
      actionItems: ["发送中英文BP"]
    )
    let client = FakePostProcessingClient(
      organizedTranscript: fixture.organizedTranscript,
      analysisResult: .success(analysis)
    )
    let processor = MeetingPostProcessor(paths: fixture.paths, client: client)

    let result = try await processor.process(fixture.session)

    #expect(result.status == .exported)
    #expect(result.summary == analysis.summary)
    #expect(result.keyPoints == analysis.keyPoints)
    #expect(result.liveTranscript == fixture.sourceTranscript)
    #expect(result.organizedTranscript == fixture.organizedTranscript)
    #expect(result.errorMessage == nil)
  }

  private func makeFixture() async throws -> (
    paths: RuntimePaths,
    session: NativeMeetingSession,
    sourceTranscript: String,
    organizedTranscript: String
  ) {
    let baseDirectory = FileManager.default.temporaryDirectory
      .appending(path: "WalleBrainPostProcessorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let paths = RuntimePaths(baseDirectory: baseDirectory)
    let dictionaryURL = try await TermDictionaryStore(paths: paths).ensureExists()
    let store = MeetingSessionStore(paths: paths)
    var session = try await store.createSession(
      title: "后处理测试",
      mode: .normal,
      dictionaryPath: dictionaryURL.path(percentEncoded: false),
      selectedInput: AudioInputDevice(id: "manual-input", name: "Manual Input")
    )
    let sourceTranscript = (0 ..< 50)
      .map { "第\($0 + 1)段讨论神策AI增长团队、客户世界模型和融资安排。" }
      .joined(separator: "\n")
    let organizedTranscript = (0 ..< 30)
      .map { "A：第\($0 + 1)部分讨论神策AI增长团队与客户世界模型。" }
      .joined(separator: "\n")
    session.status = .processing
    session.liveTranscript = sourceTranscript
    session.endedAt = Date()
    try await store.save(session)

    return (paths, session, sourceTranscript, organizedTranscript)
  }
}

private enum FakePostProcessingError: Error, Sendable {
  case analysisFailed
}

private struct FakePostProcessingClient: MeetingPostProcessingClient {
  let organizedTranscript: String
  let analysisResult: Result<LLMPostProcessingResult, FakePostProcessingError>

  func organizeTranscript(
    transcript: String,
    dictionary: TermDictionary
  ) async throws -> OrganizedTranscriptResult {
    OrganizedTranscriptResult(
      provider: "fixture",
      model: "fixture-pro",
      transcript: organizedTranscript
    )
  }

  func analyzeOrganizedTranscript(
    _ transcript: String,
    preferredModel: String?
  ) async throws -> LLMPostProcessingResult {
    try analysisResult.get()
  }
}
