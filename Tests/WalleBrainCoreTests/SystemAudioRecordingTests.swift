import AVFoundation
import Foundation
import Testing
@testable import WalleBrainCore

struct SystemAudioRecordingTests {
  @Test
  func namesSiblingFilesAfterPrimaryRecording() {
    let primary = URL(fileURLWithPath: "/data/runtime/native/MeetingAudio/2026-10-18 10-00-44 新会议 09 58.caf")

    #expect(
      MeetingAudioFiles.microphoneCaptureURL(forPrimary: primary).path(percentEncoded: false)
        == "/data/runtime/native/MeetingAudio/2026-10-18 10-00-44 新会议 09 58.mic.caf"
    )
    #expect(
      MeetingAudioFiles.systemAudioURL(forPrimary: primary).path(percentEncoded: false)
        == "/data/runtime/native/MeetingAudio/2026-10-18 10-00-44 新会议 09 58.system.caf"
    )
  }

  @Test
  func roundTripsSystemAudioPathAndDecodesLegacySessions() throws {
    let session = NativeMeetingSession(
      title: "双轨会议",
      mode: .normal,
      status: .recording,
      startedAt: Date(timeIntervalSince1970: 100),
      dictionaryPath: "/tmp/dictionary.md",
      audioFilePath: "/tmp/meeting.caf",
      systemAudioFilePath: "/tmp/meeting.system.caf",
      sessionJSONPath: "/tmp/session.json",
      sessionMarkdownPath: "/tmp/session.md"
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(NativeMeetingSession.self, from: encoder.encode(session))
    #expect(decoded.systemAudioFilePath == "/tmp/meeting.system.caf")
    #expect(decoded == session)

    let legacy = """
    {"actionItems":[],"audioFilePath":"/tmp/audio.caf","dictionaryPath":"/tmp/d.md",
     "id":"11111111-1111-1111-1111-111111111111","keyPoints":[],"liveTranscript":"",
     "mode":"normal","sessionJSONPath":"/tmp/s.json","sessionMarkdownPath":"/tmp/s.md",
     "startedAt":"1970-01-01T00:01:40Z","status":"exported","title":"旧会议","transcriptChunks":[]}
    """
    #expect(try decoder.decode(NativeMeetingSession.self, from: Data(legacy.utf8)).systemAudioFilePath == nil)
  }

  @Test
  func writerProducesPlayableAACFile() throws {
    let directory = makeTemporaryDirectory()
    let url = directory.appending(path: "meeting.system.caf", directoryHint: .notDirectory)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let writer = try AudioBufferFileWriter(url: url, format: format)

    for _ in 0 ..< 20 {
      writer.write(sineBuffer(format: format, frames: 1_600))
    }
    writer.close()
    writer.close()

    #expect(writer.failure == nil)
    #expect(writer.framesWritten == 32_000)
    #expect(MeetingAudioFiles.containsAudio(at: url))
    let file = try AVAudioFile(forReading: url)
    #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 2.0) < 0.1)
  }

  @Test
  func writerWithoutBuffersLeavesNoAudio() throws {
    let url = makeTemporaryDirectory().appending(path: "silent.system.caf", directoryHint: .notDirectory)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let writer = try AudioBufferFileWriter(url: url, format: format)
    writer.close()

    #expect(MeetingAudioFiles.containsAudio(at: url) == false)
    #expect(MeetingAudioFiles.containsAudio(at: url.appending(path: "missing")) == false)
  }

  @Test
  func exportsSystemAudioPathOnlyWhenPresent() async throws {
    let paths = RuntimePaths(baseDirectory: makeTemporaryDirectory())
    let exporter = NoteExporter(paths: paths)

    let withSystem = try await exporter.export(note: makeNote(title: "双轨", systemAudioFilePath: "/tmp/a.system.caf"))
    let withoutSystem = try await exporter.export(note: makeNote(title: "单轨", systemAudioFilePath: nil))

    let withSystemMarkdown = try String(contentsOf: withSystem, encoding: .utf8)
    let withoutSystemMarkdown = try String(contentsOf: withoutSystem, encoding: .utf8)
    #expect(withSystemMarkdown.contains("audio_file: /tmp/a.caf\nsystem_audio_file: /tmp/a.system.caf\n---"))
    #expect(!withoutSystemMarkdown.contains("system_audio_file"))
    #expect(withoutSystemMarkdown.contains("audio_file: /tmp/a.caf\n---"))
  }

  @Test
  func deletingSessionRemovesSystemAudioToo() async throws {
    let paths = RuntimePaths(baseDirectory: makeTemporaryDirectory())
    let store = MeetingSessionStore(paths: paths)
    var session = try await store.createSession(
      title: "删除测试",
      mode: .normal,
      dictionaryPath: "/tmp/dictionary.md",
      selectedInput: AudioInputDevice(id: "mixed-audio:test", name: "Mixed")
    )
    let primary = URL(fileURLWithPath: session.audioFilePath)
    let system = MeetingAudioFiles.systemAudioURL(forPrimary: primary)
    try Data("mic".utf8).write(to: primary)
    try Data("system".utf8).write(to: system)
    session.systemAudioFilePath = system.path(percentEncoded: false)
    try await store.save(session)

    try await store.delete(session)

    #expect(!FileManager.default.fileExists(atPath: primary.path(percentEncoded: false)))
    #expect(!FileManager.default.fileExists(atPath: system.path(percentEncoded: false)))
  }

  private func makeNote(title: String, systemAudioFilePath: String?) -> NativeMeetingNote {
    NativeMeetingNote(
      title: title,
      startedAt: Date(timeIntervalSince1970: 100),
      endedAt: nil,
      transcript: "",
      liveTranscript: "",
      summary: "摘要",
      organizedTranscript: "",
      keyPoints: [],
      actionItems: [],
      dictionaryPath: "/tmp/d.md",
      audioFilePath: "/tmp/a.caf",
      systemAudioFilePath: systemAudioFilePath,
      provider: "fixture",
      model: "fixture"
    )
  }

  private func sineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    let samples = buffer.floatChannelData![0]
    for frame in 0 ..< Int(frames) {
      samples[frame] = 0.3 * sin(Float(frame) * 2 * .pi * 440 / Float(format.sampleRate))
    }
    return buffer
  }

  private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "WalleBrainSystemAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
