import AVFoundation
import Foundation
import Speech

public actor LiveMeetingCoordinator {
  private let paths: RuntimePaths
  private let permissionCoordinator = PermissionCoordinator()
  private let dictionaryStore: TermDictionaryStore
  private let compiler: CustomLanguageModelCompiler
  private let sessionStore: MeetingSessionStore
  private let postProcessor: MeetingPostProcessor
  private let microphoneRecorder = MicrophoneCaptureService()
  private let systemAudioRecorder = SystemAudioCaptureService()
  private let mixedRecorder = MixedCaptureService()
  private let onUpdate: @Sendable (NativeMeetingSession) async -> Void

  private var currentSession: NativeMeetingSession?
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var analyzerTask: Task<Void, Error>?
  private var resultsTask: Task<Void, Never>?
  private var transcriptChunks: [String: TranscriptChunk] = [:]
  private let transcriptAssembler = TranscriptAssembler()
  private var activeInputID: String?
  private let liveDebugEnabled = ProcessInfo.processInfo.environment["WALLEBRAIN_DEBUG_LIVE"] == "1"
  private let liveDisableResultsTask = ProcessInfo.processInfo.environment["WALLEBRAIN_DISABLE_RESULTS_TASK"] == "1"
  private let liveDisableAnalyzerTask = ProcessInfo.processInfo.environment["WALLEBRAIN_DISABLE_ANALYZER_TASK"] == "1"

  public init(
    paths: RuntimePaths,
    onUpdate: @escaping @Sendable (NativeMeetingSession) async -> Void
  ) {
    self.paths = paths
    self.dictionaryStore = TermDictionaryStore(paths: paths)
    self.compiler = CustomLanguageModelCompiler(paths: paths)
    self.sessionStore = MeetingSessionStore(paths: paths)
    self.postProcessor = MeetingPostProcessor(paths: paths)
    self.onUpdate = onUpdate
  }

  public func availableInputs() -> [AudioInputDevice] {
    AudioInputCatalog.availableInputs()
  }

  public func preferredInput() -> AudioInputDevice? {
    AudioInputCatalog.preferredInput(from: availableInputs())
  }

  public func startMeeting(
    title: String,
    mode: MeetingMode,
    preferredInputID: String? = nil
  ) async throws {
    if let currentSession, [.preparing, .recording, .processing].contains(currentSession.status) {
      throw WalleBrainError.invalidResponse("A meeting is already running.")
    }

    let devices = availableInputs()
    let selectedInput = devices.first(where: { $0.id == preferredInputID })
      ?? AudioInputCatalog.preferredInput(from: devices)
    guard let selectedInput else {
      throw WalleBrainError.invalidResponse("No audio input device is available.")
    }
    let isManualInput = AudioInputCatalog.isManualInput(id: selectedInput.id)

    let requiresSystemAudio = AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) || AudioInputCatalog.isMixedInput(id: selectedInput.id)
    let requiresMicrophone = !AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) && !isManualInput

    if requiresMicrophone {
      let microphoneGranted = await permissionCoordinator.requestMicrophoneAccess()
      guard microphoneGranted else {
        throw WalleBrainError.invalidResponse("Microphone access was denied.")
      }
    }

    let dictionaryPath = try await dictionaryStore.ensureExists()
    if !isManualInput {
      let speechStatus = await permissionCoordinator.requestSpeechAccess()
      guard speechStatus == .authorized else {
        throw WalleBrainError.invalidResponse("Speech recognition access was denied.")
      }

      let dictionary = try await dictionaryStore.loadDictionary()
      let assets = try await compiler.compile(dictionary: dictionary)
      _ = await compiler.configuration(for: assets)
    }

    let startedAt = Date()
    var session = try await sessionStore.createSession(
      title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "会议记录" : title,
      mode: mode,
      dictionaryPath: dictionaryPath.path(percentEncoded: false),
      selectedInput: selectedInput,
      startedAt: startedAt
    )
    currentSession = session
    transcriptChunks = [:]
    await emit(session)

    if isManualInput {
      session.status = .recording
      currentSession = session
      try await persistCurrentSession()
      cleanupTransientState()
      return
    }

    do {
      await debug("session-created")
      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN"))
        ?? Locale(identifier: "zh_CN")
      await debug("locale-ready")
      let transcriber = SpeechTranscriber(
        locale: locale,
        preset: .timeIndexedProgressiveTranscription
      )
      self.transcriber = transcriber
      await debug("transcriber-created")

      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        await debug("asset-request-created")
        try await request.downloadAndInstall()
        await debug("asset-request-installed")
      }

      let preferredAnalyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
      await debug("best-format-ready")
      let analyzerFormat = preferredAnalyzerFormat
        ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
      await debug("analyzer-format-created")

      let capture: StartedCapture
      if requiresSystemAudio {
        if await permissionCoordinator.hasScreenCaptureAccess() == false {
          _ = await permissionCoordinator.requestScreenCaptureAccess()
        }
      }

      if AudioInputCatalog.isMixedInput(id: selectedInput.id) {
        guard
          let microphoneID = AudioInputCatalog.microphoneID(forMixedInput: selectedInput.id),
          let hardwareInput = devices.first(where: { $0.id == microphoneID })
        else {
          throw WalleBrainError.invalidResponse("Mixed input microphone device is unavailable.")
        }

        let systemAudioInput = AudioInputDevice(id: AudioInputCatalog.systemAudioInputID, name: "System Audio")
        capture = try await mixedRecorder.start(
          microphoneDevice: hardwareInput,
          systemAudioDevice: systemAudioInput,
          outputURL: URL(fileURLWithPath: session.audioFilePath),
          targetFormat: analyzerFormat
        )
      } else if AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) {
        capture = try await systemAudioRecorder.start(
          device: selectedInput,
          outputURL: URL(fileURLWithPath: session.audioFilePath),
          targetFormat: analyzerFormat
        )
      } else {
        capture = try await microphoneRecorder.start(
          device: selectedInput,
          outputURL: URL(fileURLWithPath: session.audioFilePath),
          targetFormat: analyzerFormat
        )
      }
      await debug("capture-started")

      session.selectedInput = capture.inputDevice
      session.status = .recording
      currentSession = session
      activeInputID = capture.inputDevice.id
      try await persistCurrentSession()
      await debug("recording-persisted")

      let analyzer = SpeechAnalyzer(modules: [transcriber])
      await debug("analyzer-created")
      try await analyzer.prepareToAnalyze(in: capture.audioFormat)
      await debug("analyzer-prepared")
      self.analyzer = analyzer

      if liveDisableAnalyzerTask {
        await debug("analyzer-task-skipped")
      } else {
        analyzerTask = makeAnalyzerTask(analyzer: analyzer, stream: capture.stream)
        await debug("analyzer-task-created")
      }
      if liveDisableResultsTask {
        await debug("results-task-skipped")
      } else {
        resultsTask = makeResultsTask(transcriber: transcriber)
        await debug("results-task-created")
      }
    } catch {
      await debug("start-failed: \(error.localizedDescription)")
      await fail(message: error.localizedDescription)
      throw error
    }
  }

  public func stopMeetingAndProcess() async throws {
    guard var session = currentSession else {
      throw WalleBrainError.invalidResponse("No running meeting to stop.")
    }
    let isManualInput = AudioInputCatalog.isManualInput(id: session.selectedInput?.id ?? "")

    session.status = .processing
    session.endedAt = Date()
    currentSession = session
    try await persistCurrentSession()

    do {
      if !isManualInput {
        try await stopActiveCapture()
        try await ensurePrimaryAudioArtifactExists(for: session)
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = try await analyzerTask?.value
        analyzerTask = nil
        await resultsTask?.value
        resultsTask = nil
      }

      session = try await postProcessor.process(currentSession ?? session)
      currentSession = session
      try await persistCurrentSession()
      cleanupTransientState()
    } catch {
      await fail(message: error.localizedDescription)
      throw error
    }
  }

  public func latestSession() -> NativeMeetingSession? {
    currentSession
  }

  public func updateMeetingTitle(_ title: String) async throws {
    guard var session = currentSession else {
      return
    }

    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    session.title = normalized.isEmpty ? "会议记录" : normalized
    currentSession = session
    try await persistCurrentSession()
  }

  public func updateManualTranscript(_ transcript: String) async throws {
    guard var session = currentSession else {
      return
    }

    guard AudioInputCatalog.isManualInput(id: session.selectedInput?.id ?? "") else {
      return
    }

    let normalized = transcript
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")

    session.liveTranscript = normalized
    session.transcriptChunks = normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? []
      : [
        TranscriptChunk(
          id: "manual-input",
          startSeconds: 0,
          durationSeconds: 0,
          text: normalized
        )
      ]
    currentSession = session
    try await persistCurrentSession()
  }

  private func consume(_ result: SpeechTranscriber.Result) async {
    guard var session = currentSession else {
      return
    }

    await debug("consume-enter")

    let startSeconds = result.range.start.seconds.isFinite ? result.range.start.seconds : 0
    let durationSeconds = result.range.duration.seconds.isFinite ? result.range.duration.seconds : 0
    let id = Self.chunkID(startSeconds: startSeconds, durationSeconds: durationSeconds)
    let text = String(result.text.characters)
    await debug("consume-text-ready")
    let chunk = TranscriptChunk(
      id: id,
      startSeconds: startSeconds,
      durationSeconds: durationSeconds,
      text: text
    )
    let mergedChunks = transcriptAssembler.merged(
      chunks: Array(transcriptChunks.values),
      with: chunk
    )
    transcriptChunks = Dictionary(uniqueKeysWithValues: mergedChunks.map { ($0.id, $0) })
    session.transcriptChunks = mergedChunks
    session.liveTranscript = transcriptAssembler.liveTranscript(from: mergedChunks)

    currentSession = session

    do {
      try await persistCurrentSession()
    } catch {
      await fail(message: error.localizedDescription)
    }
  }

  private func persistCurrentSession() async throws {
    guard let currentSession else {
      return
    }

    try await sessionStore.save(currentSession)
    await emit(currentSession)
  }

  private func emit(_ session: NativeMeetingSession) async {
    await onUpdate(session)
  }

  private func fail(message: String) async {
    guard var session = currentSession else {
      return
    }

    session.status = .failed
    session.errorMessage = message
    currentSession = session
    try? await sessionStore.save(session)
    await onUpdate(session)
    cleanupTransientState()
  }

  private func cleanupTransientState() {
    analyzer = nil
    transcriber = nil
    analyzerTask = nil
    resultsTask = nil
    activeInputID = nil
  }

  private func makeAnalyzerTask(
    analyzer: SpeechAnalyzer,
    stream: AsyncStream<AnalyzerInput>
  ) -> Task<Void, Error> {
    Task {
      try await Self.runAnalyzer(analyzer: analyzer, stream: stream)
    }
  }

  private func makeResultsTask(transcriber: SpeechTranscriber) -> Task<Void, Never> {
    Task {
      await self.consumeResults(from: transcriber)
    }
  }

  private static func runAnalyzer(
    analyzer: SpeechAnalyzer,
    stream: AsyncStream<AnalyzerInput>
  ) async throws {
    try await analyzer.start(inputSequence: stream)
  }

  private func consumeResults(from transcriber: SpeechTranscriber) async {
    do {
      for try await result in transcriber.results {
        await debug("result-received")
        await consume(result)
      }
    } catch {
      await fail(message: error.localizedDescription)
    }
  }

  private static func chunkID(startSeconds: Double, durationSeconds: Double) -> String {
    String(format: "%.3f-%.3f", startSeconds, durationSeconds)
  }

  private func stopActiveCapture() async throws {
    if let activeInputID, AudioInputCatalog.isMixedInput(id: activeInputID) {
      try await mixedRecorder.stop()
    } else if let activeInputID, AudioInputCatalog.isSystemAudioInput(id: activeInputID) {
      try await systemAudioRecorder.stop()
    } else {
      try await microphoneRecorder.stop()
    }
    activeInputID = nil
  }

  private func debug(_ message: String) async {
    guard liveDebugEnabled else {
      return
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let url = paths.nativeDirectory.appending(path: "live-debug.log", directoryHint: .notDirectory)

    do {
      try paths.ensureDirectories()
      if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
      } else {
        try line.write(to: url, atomically: true, encoding: .utf8)
      }
    } catch {
      // Best-effort debug logging only.
    }
  }

  private func ensurePrimaryAudioArtifactExists(for session: NativeMeetingSession) async throws {
    let fileManager = FileManager.default
    let outputURL = URL(fileURLWithPath: session.audioFilePath)

    if fileManager.fileExists(atPath: outputURL.path(percentEncoded: false)) {
      return
    }

    let candidates = siblingAudioCandidates(for: outputURL)
    let deadline = Date().addingTimeInterval(8)

    while Date() < deadline {
      if let bestSource = try bestAvailableAudioSource(from: candidates, fileManager: fileManager) {
        try fileManager.copyItem(at: bestSource, to: outputURL)
        return
      }

      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func siblingAudioCandidates(for outputURL: URL) -> [URL] {
    let base = outputURL.deletingPathExtension()
    return [
      base.deletingLastPathComponent()
        .appending(path: "\(base.lastPathComponent).mic.caf", directoryHint: .notDirectory),
      base.deletingLastPathComponent()
        .appending(path: "\(base.lastPathComponent).system.caf", directoryHint: .notDirectory),
    ]
  }

  private func bestAvailableAudioSource(from candidates: [URL], fileManager: FileManager) throws -> URL? {
    var bestURL: URL?
    var bestSize: Int64 = -1

    for candidate in candidates {
      guard fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) else {
        continue
      }

      let size = Int64((try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      if size > bestSize {
        bestURL = candidate
        bestSize = size
      }
    }

    return bestSize > 0 ? bestURL : nil
  }
}
