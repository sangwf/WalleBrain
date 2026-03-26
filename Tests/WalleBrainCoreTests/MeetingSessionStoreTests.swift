import Foundation
import Testing
@testable import WalleBrainCore

struct MeetingSessionStoreTests {
  @Test
  func listsSessionsByStartedAtDescending() async throws {
    let paths = RuntimePaths(baseDirectory: makeTemporaryBaseDirectory())
    let store = MeetingSessionStore(paths: paths)

    _ = try await createSession(
      store: store,
      title: "较早会议",
      startedAt: Date(timeIntervalSince1970: 100)
    )
    _ = try await createSession(
      store: store,
      title: "较晚会议",
      startedAt: Date(timeIntervalSince1970: 200)
    )

    let sessions = try await store.listSessions(limit: 10)

    #expect(sessions.count == 2)
    #expect(sessions.map(\.title) == ["较晚会议", "较早会议"])
  }

  @Test
  func skipsUnreadableSessionFiles() async throws {
    let paths = RuntimePaths(baseDirectory: makeTemporaryBaseDirectory())
    let store = MeetingSessionStore(paths: paths)

    let validSession = try await createSession(
      store: store,
      title: "有效会议",
      startedAt: Date(timeIntervalSince1970: 100)
    )

    let brokenURL = paths.nativeMeetingSessionsDirectory.appending(path: "broken.session.json", directoryHint: .notDirectory)
    try paths.ensureDirectories()
    try "{ not-json }".write(to: brokenURL, atomically: true, encoding: .utf8)

    let sessions = try await store.listSessions(limit: 10)

    #expect(sessions.count == 1)
    #expect(sessions.first?.id == validSession.id)
  }

  private func createSession(
    store: MeetingSessionStore,
    title: String,
    startedAt: Date
  ) async throws -> NativeMeetingSession {
    try await store.createSession(
      title: title,
      mode: .normal,
      dictionaryPath: "/tmp/dictionary.md",
      selectedInput: AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Pro麦克风"),
      startedAt: startedAt
    )
  }

  private func makeTemporaryBaseDirectory() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "WalleBrainTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
