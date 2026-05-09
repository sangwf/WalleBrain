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
  private let onAudioLevel: @Sendable (AudioLevelSnapshot) async -> Void

  private var currentSession: NativeMeetingSession?
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var realtimeTranscriber: OpenAIRealtimeTranscriptionClient?
  private var analyzerTask: Task<Void, Error>?
  private var resultsTask: Task<Void, Never>?
  private var realtimeResultsTask: Task<Void, Never>?
  private var backgroundProcessingTasks: [UUID: Task<Void, Never>] = [:]
  private var transcriptChunks: [String: TranscriptChunk] = [:]
  private let transcriptAssembler = TranscriptAssembler()
  private var realtimeStableTranscript = ""
  private var isStoppingMeeting = false
  private var activeInputID: String?
  private let liveDebugEnabled = ProcessInfo.processInfo.environment["WALLEBRAIN_DEBUG_LIVE"] == "1"
  private let liveDisableResultsTask = ProcessInfo.processInfo.environment["WALLEBRAIN_DISABLE_RESULTS_TASK"] == "1"
  private let liveDisableAnalyzerTask = ProcessInfo.processInfo.environment["WALLEBRAIN_DISABLE_ANALYZER_TASK"] == "1"

  public init(
    paths: RuntimePaths,
    onUpdate: @escaping @Sendable (NativeMeetingSession) async -> Void,
    onAudioLevel: @escaping @Sendable (AudioLevelSnapshot) async -> Void = { _ in }
  ) {
    self.paths = paths
    self.dictionaryStore = TermDictionaryStore(paths: paths)
    self.compiler = CustomLanguageModelCompiler(paths: paths)
    self.sessionStore = MeetingSessionStore(paths: paths)
    self.postProcessor = MeetingPostProcessor(paths: paths)
    self.onUpdate = onUpdate
    self.onAudioLevel = onAudioLevel
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
    preferredInputID: String? = nil,
    transcriptionMode: TranscriptionQualityMode = .local
  ) async throws {
    await trace("startMeeting enter title=\(title) mode=\(mode.rawValue) transcription=\(transcriptionMode.rawValue) input=\(preferredInputID ?? "nil")")
    if let currentSession, [.preparing, .recording].contains(currentSession.status) {
      throw WalleBrainError.invalidResponse("A meeting is already running.")
    }

    let devices = availableInputs()
    let selectedInput = devices.first(where: { $0.id == preferredInputID })
      ?? AudioInputCatalog.preferredInput(from: devices)
    guard let selectedInput else {
      throw WalleBrainError.invalidResponse("No audio input device is available.")
    }
    await trace("selected input id=\(selectedInput.id) name=\(selectedInput.name)")
    let isManualInput = AudioInputCatalog.isManualInput(id: selectedInput.id)
    let effectiveTranscriptionMode: TranscriptionQualityMode = isManualInput ? .local : transcriptionMode

    let requiresSystemAudio = AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) || AudioInputCatalog.isMixedInput(id: selectedInput.id)
    let requiresMicrophone = !AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) && !isManualInput
    let realtimeConfiguration: RealtimeTranscriptionConfiguration?

    if requiresMicrophone {
      let microphoneGranted = await permissionCoordinator.requestMicrophoneAccess()
      guard microphoneGranted else {
        throw WalleBrainError.invalidResponse("Microphone access was denied.")
      }
    }

    let dictionaryPath = try await dictionaryStore.ensureExists()
    await trace("dictionary ready path=\(dictionaryPath.path(percentEncoded: false))")
    if effectiveTranscriptionMode == .highQuality {
      realtimeConfiguration = try RealtimeTranscriptionConfigurationResolver().resolve()
      await trace("realtime config resolved model=\(realtimeConfiguration?.model ?? "")")
    } else {
      realtimeConfiguration = nil
    }

    if !isManualInput && effectiveTranscriptionMode == .local {
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
      title: Self.normalizedMeetingTitle(title, date: startedAt),
      mode: mode,
      dictionaryPath: dictionaryPath.path(percentEncoded: false),
      selectedInput: selectedInput,
      startedAt: startedAt
    )
    currentSession = session
    transcriptChunks = [:]
    realtimeStableTranscript = ""
    await trace("session created json=\(session.sessionJSONPath) audio=\(session.audioFilePath)")
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
      let analyzerFormat: AVAudioFormat
      let transcriber: SpeechTranscriber?
      if effectiveTranscriptionMode == .highQuality {
        analyzerFormat = OpenAIRealtimeTranscriptionClient.audioFormat
        transcriber = nil
        await debug("realtime-format-created")
      } else {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh_CN"))
          ?? Locale(identifier: "zh_CN")
        await debug("locale-ready")
        let localTranscriber = SpeechTranscriber(
          locale: locale,
          preset: .timeIndexedProgressiveTranscription
        )
        self.transcriber = localTranscriber
        transcriber = localTranscriber
        await debug("transcriber-created")

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [localTranscriber]) {
          await debug("asset-request-created")
          try await request.downloadAndInstall()
          await debug("asset-request-installed")
        }

        let preferredAnalyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [localTranscriber])
        await debug("best-format-ready")
        analyzerFormat = preferredAnalyzerFormat
          ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        await debug("analyzer-format-created")
      }

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
        await trace("mixed capture started")
      } else if AudioInputCatalog.isSystemAudioInput(id: selectedInput.id) {
        capture = try await systemAudioRecorder.start(
          device: selectedInput,
          outputURL: URL(fileURLWithPath: session.audioFilePath),
          targetFormat: analyzerFormat
        )
        await trace("system capture started")
      } else {
        capture = try await microphoneRecorder.start(
          device: selectedInput,
          outputURL: URL(fileURLWithPath: session.audioFilePath),
          targetFormat: analyzerFormat
        )
        await trace("microphone capture started")
      }
      await debug("capture-started")
      let meteredStream = meteredStream(from: capture.stream)

      session.selectedInput = capture.inputDevice
      session.transcriptionProvider = effectiveTranscriptionMode == .highQuality
        ? realtimeConfiguration?.provider
        : "Apple Speech"
      session.transcriptionModel = effectiveTranscriptionMode == .highQuality
        ? realtimeConfiguration?.model
        : "SpeechTranscriber"
      session.status = .recording
      currentSession = session
      activeInputID = capture.inputDevice.id
      try await persistCurrentSession()
      await debug("recording-persisted")

      if effectiveTranscriptionMode == .highQuality, let realtimeConfiguration {
        let realtimeTranscriber = OpenAIRealtimeTranscriptionClient(
          configuration: realtimeConfiguration,
          debugLogURL: paths.nativeDirectory.appending(path: "realtime-debug.log", directoryHint: .notDirectory)
        )
        self.realtimeTranscriber = realtimeTranscriber
        let dictionary = try await dictionaryStore.loadDictionary()
        realtimeResultsTask = makeRealtimeResultsTask(
          transcriber: realtimeTranscriber,
          stream: meteredStream,
          prompt: Self.realtimePrompt(from: dictionary)
        )
        await debug("realtime-task-created")
        await trace("realtime task created")
      } else {
        guard let transcriber else {
          throw WalleBrainError.invalidResponse("Local speech transcriber was not initialized.")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        await debug("analyzer-created")
        try await analyzer.prepareToAnalyze(in: capture.audioFormat)
        await debug("analyzer-prepared")
        self.analyzer = analyzer

        if liveDisableAnalyzerTask {
          await debug("analyzer-task-skipped")
        } else {
          analyzerTask = makeAnalyzerTask(analyzer: analyzer, stream: meteredStream)
          await debug("analyzer-task-created")
        }
        if liveDisableResultsTask {
          await debug("results-task-skipped")
        } else {
          resultsTask = makeResultsTask(transcriber: transcriber)
          await debug("results-task-created")
        }
      }
    } catch {
      await trace("startMeeting catch error=\(error.localizedDescription)")
      await debug("start-failed: \(error.localizedDescription)")
      await fail(message: error.localizedDescription)
      throw error
    }
  }

  public func stopMeetingAndProcess() async throws {
    guard var session = currentSession else {
      throw WalleBrainError.invalidResponse("No running meeting to stop.")
    }
    let processingSessionID = session.id
    let isManualInput = AudioInputCatalog.isManualInput(id: session.selectedInput?.id ?? "")

    session.status = .processing
    session.endedAt = Date()
    currentSession = session
    try await persistCurrentSession()

    do {
      if !isManualInput {
        isStoppingMeeting = true
        try await stopActiveCapture()
        try await ensurePrimaryAudioArtifactExists(for: session)
        if let realtimeResultsTask {
          await realtimeResultsTask.value
          self.realtimeResultsTask = nil
        } else {
          try await analyzer?.finalizeAndFinishThroughEndOfInput()
          _ = try await analyzerTask?.value
          analyzerTask = nil
          await resultsTask?.value
          resultsTask = nil
        }
        isStoppingMeeting = false
      }

      let processingSession = currentSession ?? session
      cleanupTransientState()
      currentSession = nil
      startBackgroundProcessing(for: processingSession, sessionID: processingSessionID)
    } catch {
      isStoppingMeeting = false
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

    session.title = Self.normalizedMeetingTitle(title)
    currentSession = session
    try await persistCurrentSession()
  }

  private static func normalizedMeetingTitle(_ title: String, date: Date = Date()) -> String {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty else {
      return normalized
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return "新会议 \(formatter.string(from: date))"
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

  private func consume(_ result: RealtimeTranscriptionResult) async {
    guard var session = currentSession else {
      return
    }

    let text = mergedRealtimeTranscript(with: result.text, isPreview: result.id == "realtime-streaming")
    let chunk = TranscriptChunk(
      id: "realtime-live",
      startSeconds: 0,
      durationSeconds: max(result.startSeconds + result.durationSeconds, 0),
      text: text
    )
    transcriptChunks = [chunk.id: chunk]
    session.transcriptChunks = [chunk]
    session.liveTranscript = text

    currentSession = session

    do {
      try await persistCurrentSession()
    } catch {
      await fail(message: error.localizedDescription)
    }
  }

  private func mergedRealtimeTranscript(with incoming: String, isPreview: Bool) -> String {
    let normalizedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedIncoming.isEmpty else {
      return realtimeStableTranscript
    }

    if isPreview {
      return Self.appendDeduplicated(normalizedIncoming, to: realtimeStableTranscript)
    }

    realtimeStableTranscript = Self.appendDeduplicated(normalizedIncoming, to: realtimeStableTranscript)
    return realtimeStableTranscript
  }

  private static func appendDeduplicated(_ incoming: String, to existing: String) -> String {
    guard !incoming.isEmpty else {
      return existing
    }
    guard !existing.isEmpty else {
      return incoming
    }

    if existing.hasSuffix(incoming) {
      return existing
    }

    let maxOverlap = min(existing.count, incoming.count)
    if maxOverlap > 0 {
      for length in stride(from: maxOverlap, through: 1, by: -1) {
        let existingSuffix = String(existing.suffix(length))
        let incomingPrefix = String(incoming.prefix(length))
        if existingSuffix == incomingPrefix {
          return existing + String(incoming.dropFirst(length))
        }
      }
    }

    return existing + (existing.last?.isWhitespace == true || incoming.first?.isWhitespace == true ? "" : " ") + incoming
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
      await trace("fail without currentSession message=\(message)")
      return
    }

    await trace("fail session=\(session.id.uuidString) message=\(message)")
    await realtimeTranscriber?.close()
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
    realtimeTranscriber = nil
    analyzerTask = nil
    resultsTask = nil
    realtimeResultsTask = nil
    realtimeStableTranscript = ""
    isStoppingMeeting = false
    activeInputID = nil
  }

  private func startBackgroundProcessing(for session: NativeMeetingSession, sessionID: UUID) {
    backgroundProcessingTasks[sessionID]?.cancel()
    backgroundProcessingTasks[sessionID] = Task { [weak self] in
      await self?.runBackgroundProcessing(for: session, sessionID: sessionID)
    }
  }

  private func runBackgroundProcessing(for session: NativeMeetingSession, sessionID: UUID) async {
    defer { backgroundProcessingTasks[sessionID] = nil }

    do {
      let processedSession = try await postProcessor.process(session)
      try await sessionStore.save(processedSession)
      await emit(processedSession)
    } catch {
      var failedSession = session
      failedSession.status = .failed
      failedSession.errorMessage = error.localizedDescription
      do {
        try await sessionStore.save(failedSession)
      } catch {
        // Best-effort persistence; surface the failed state if possible.
      }
      await emit(failedSession)
    }
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

  private func makeRealtimeResultsTask(
    transcriber: OpenAIRealtimeTranscriptionClient,
    stream: AsyncStream<AnalyzerInput>,
    prompt: String
  ) -> Task<Void, Never> {
    Task {
      do {
        try await transcriber.run(stream: stream, prompt: prompt) { result in
          await self.consume(result)
        }
      } catch {
        guard !Task.isCancelled else {
          return
        }
        if self.shouldIgnoreRealtimeErrorDuringStop(error) {
          return
        }
        await self.fail(message: error.localizedDescription)
      }
    }
  }

  private func shouldIgnoreRealtimeErrorDuringStop(_ error: Error) -> Bool {
    guard isStoppingMeeting else {
      return false
    }

    let description = error.localizedDescription.lowercased()
    return description.contains("socket is not connected")
      || description.contains("socket not connected")
      || description.contains("network connection was lost")
      || description.contains("cancelled")
  }

  private func meteredStream(from source: AsyncStream<AnalyzerInput>) -> AsyncStream<AnalyzerInput> {
    AsyncStream { continuation in
      let task = Task {
        var lastEmit = ContinuousClock.now
        for await input in source {
          let level = Self.audioLevelSnapshot(for: input.buffer)
          let now = ContinuousClock.now
          let elapsed = lastEmit.duration(to: now)
          if elapsed >= .milliseconds(150) || level.peakLevel >= 0.04 {
            lastEmit = now
            await onAudioLevel(level)
          }
          continuation.yield(input)
        }

        await onAudioLevel(AudioLevelSnapshot(
          rmsLevel: 0,
          peakLevel: 0,
          isReceivingAudio: false
        ))
        continuation.finish()
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  private static func runAnalyzer(
    analyzer: SpeechAnalyzer,
    stream: AsyncStream<AnalyzerInput>
  ) async throws {
    try await analyzer.start(inputSequence: stream)
  }

  private static func audioLevelSnapshot(for buffer: AVAudioPCMBuffer) -> AudioLevelSnapshot {
    let levels = audioLevels(for: buffer)
    return AudioLevelSnapshot(
      rmsLevel: levels.rms,
      peakLevel: levels.peak,
      isReceivingAudio: levels.peak >= 0.008 || levels.rms >= 0.003
    )
  }

  private static func audioLevels(for buffer: AVAudioPCMBuffer) -> (rms: Double, peak: Double) {
    guard buffer.frameLength > 0 else {
      return (0, 0)
    }

    if let channels = buffer.floatChannelData {
      var total = 0.0
      var peak = 0.0
      var count = 0
      for channel in 0 ..< Int(buffer.format.channelCount) {
        let pointer = channels[channel]
        for frame in 0 ..< Int(buffer.frameLength) {
          let sample = abs(Double(pointer[frame]))
          total += sample * sample
          peak = max(peak, sample)
          count += 1
        }
      }
      return count > 0 ? (sqrt(total / Double(count)), min(1, peak)) : (0, 0)
    }

    if let channels = buffer.int16ChannelData {
      var total = 0.0
      var peak = 0.0
      var count = 0
      for channel in 0 ..< Int(buffer.format.channelCount) {
        let pointer = channels[channel]
        for frame in 0 ..< Int(buffer.frameLength) {
          let sample = abs(Double(pointer[frame]) / Double(Int16.max))
          total += sample * sample
          peak = max(peak, sample)
          count += 1
        }
      }
      return count > 0 ? (sqrt(total / Double(count)), min(1, peak)) : (0, 0)
    }

    return (0, 0)
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

  private static func realtimePrompt(from dictionary: TermDictionary) -> String {
    let terms = dictionary.allTerms.prefix(120)
    guard !terms.isEmpty else {
      return "Transcribe a Chinese business meeting. Preserve English product names and technical terms as spoken."
    }

    return """
    Transcribe a Chinese business meeting. Preserve English product names and technical terms as spoken.
    Expected vocabulary: \(terms.joined(separator: ", "))
    """
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

  private func trace(_ message: String) async {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    let url = paths.nativeDirectory.appending(path: "live-flow.log", directoryHint: .notDirectory)

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
      // Best-effort diagnostics only.
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
