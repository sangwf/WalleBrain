import AVFoundation
import Foundation
import Speech

public struct RealtimeTranscriptionResult: Sendable, Hashable {
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

public final class OpenAIRealtimeTranscriptionClient: @unchecked Sendable {
  static let maximumRealtimeSessionDurationSeconds = 60.0 * 60.0
  static let proactiveRealtimeSessionRotationSeconds = 50.0 * 60.0
  static let commitIntervalSeconds = 2.5

  public static let audioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  private struct ServerEvent: Decodable {
    struct ErrorPayload: Decodable {
      let message: String?
      let type: String?
      let code: String?
    }

    let type: String
    let eventID: String?
    let itemID: String?
    let audioStartMS: Int?
    let audioEndMS: Int?
    let transcript: String?
    let text: String?
    let delta: String?
    let error: ErrorPayload?

    enum CodingKeys: String, CodingKey {
      case type
      case eventID = "event_id"
      case itemID = "item_id"
      case audioStartMS = "audio_start_ms"
      case audioEndMS = "audio_end_ms"
      case transcript
      case text
      case delta
      case error
    }
  }

  private struct ItemTiming: Sendable {
    var startMS: Int?
    var endMS: Int?
  }

  private struct EncodedAudio: Sendable {
    let base64: String
    let rms: Double
    let gain: Double
  }

  private struct SessionAudioResult: Sendable {
    let shouldRotate: Bool
    let audioSecondsSent: Double
  }

  private let configuration: RealtimeTranscriptionConfiguration
  private let urlSession: URLSession
  private let debugLogURL: URL?
  private let decoder = JSONDecoder()
  private var webSocketTask: URLSessionWebSocketTask?
  private var itemTimingByID: [String: ItemTiming] = [:]
  private var deltaTextByItemID: [String: String] = [:]
  private var streamingTranscript = ""
  private var fallbackNextStartSeconds = 0.0
  private var completedSequence = 0
  private var currentSessionAudioOffsetSeconds = 0.0

  public init(
    configuration: RealtimeTranscriptionConfiguration,
    urlSession: URLSession = .shared,
    debugLogURL: URL? = nil
  ) {
    self.configuration = configuration
    self.urlSession = urlSession
    self.debugLogURL = debugLogURL
  }

  public static func testConnection(
    configuration: RealtimeTranscriptionConfiguration,
    urlSession: URLSession = .shared
  ) async throws -> String {
    _ = try await Self.createClientSecret(configuration: configuration, prompt: "", urlSession: urlSession)
    return configuration.model
  }

  public func run(
    stream: AsyncStream<AnalyzerInput>,
    prompt: String,
    onTranscript: @escaping @Sendable (RealtimeTranscriptionResult) async -> Void
  ) async throws {
    var audioIterator = stream.makeAsyncIterator()
    var sessionIndex = 0
    var totalAudioSecondsSent = 0.0

    while !Task.isCancelled {
      sessionIndex += 1
      currentSessionAudioOffsetSeconds = totalAudioSecondsSent
      let result = try await runRealtimeSession(
        audioIterator: &audioIterator,
        prompt: prompt,
        sessionIndex: sessionIndex,
        onTranscript: onTranscript
      )
      totalAudioSecondsSent += result.audioSecondsSent

      guard result.shouldRotate else {
        return
      }
    }
  }

  public func close() async {
    await closeCurrentConnection()
  }

  static func shouldRotateRealtimeSession(afterAudioSeconds audioSeconds: Double) -> Bool {
    audioSeconds >= proactiveRealtimeSessionRotationSeconds
  }

  private func runRealtimeSession(
    audioIterator: inout AsyncStream<AnalyzerInput>.Iterator,
    prompt: String,
    sessionIndex: Int,
    onTranscript: @escaping @Sendable (RealtimeTranscriptionResult) async -> Void
  ) async throws -> SessionAudioResult {
    let clientSecret = try await Self.createClientSecret(
      configuration: configuration,
      prompt: prompt,
      urlSession: urlSession
    )
    resetPerConnectionState()
    log("client secret created model=\(configuration.model) session=\(sessionIndex)")
    let task = try makeWebSocketTask(clientSecret: clientSecret)
    webSocketTask = task
    task.resume()
    log("websocket resumed session=\(sessionIndex)")

    let receiverTask = Task {
      try await self.receiveEvents(onTranscript: onTranscript)
    }

    do {
      let result = try await sendAudioForCurrentSession(
        from: &audioIterator,
        sessionIndex: sessionIndex
      )
      if result.shouldRotate {
        log("rotating realtime session=\(sessionIndex) audioSeconds=\(String(format: "%.2f", result.audioSecondsSent))")
        try? await Task.sleep(for: .milliseconds(1_500))
      }
      await closeCurrentConnection()
      try await waitForReceiver(receiverTask, sessionIndex: sessionIndex)
      return result
    } catch {
      await closeCurrentConnection()
      receiverTask.cancel()
      _ = try? await receiverTask.value
      throw error
    }
  }

  private func closeCurrentConnection() async {
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
  }

  private func resetPerConnectionState() {
    itemTimingByID.removeAll()
    deltaTextByItemID.removeAll()
  }

  private func makeWebSocketTask(clientSecret: String) throws -> URLSessionWebSocketTask {
    guard var components = URLComponents(string: "wss://api.openai.com/v1/realtime") else {
      throw WalleBrainError.invalidResponse("Realtime transcription URL is invalid.")
    }
    components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
    guard let url = components.url else {
      throw WalleBrainError.invalidResponse("Realtime transcription URL is invalid.")
    }

    var request = URLRequest(url: url)
    request.addValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
    return urlSession.webSocketTask(with: request)
  }

  private func sendAudioForCurrentSession(
    from audioIterator: inout AsyncStream<AnalyzerInput>.Iterator,
    sessionIndex: Int
  ) async throws -> SessionAudioResult {
    var pendingAudioSeconds = 0.0
    var sessionAudioSeconds = 0.0
    var appendCount = 0
    var commitCount = 0
    var pendingSourceRMS = 0.0
    var pendingEncodedRMS = 0.0
    var pendingGain = 0.0
    var pendingMeterCount = 0
    let startedAt = ContinuousClock.now

    while let input = await audioIterator.next() {
      let rms = Self.rmsLevel(of: input.buffer)
      guard let audio = Self.encodedPCM16Audio(from: input.buffer) else {
        log("skip buffer conversion failed format=\(input.buffer.format)")
        continue
      }

      appendCount += 1
      try await sendJSON([
        "type": "input_audio_buffer.append",
        "audio": audio.base64,
      ])

      pendingAudioSeconds += Self.durationSeconds(of: input.buffer)
      sessionAudioSeconds += Self.durationSeconds(of: input.buffer)
      pendingSourceRMS += rms
      pendingEncodedRMS += audio.rms
      pendingGain += audio.gain
      pendingMeterCount += 1
      if pendingAudioSeconds >= Self.commitIntervalSeconds {
        commitCount += 1
        let meterCount = max(1, pendingMeterCount)
        log(
          "commit #\(commitCount) after append #\(appendCount) seconds=\(String(format: "%.2f", pendingAudioSeconds))"
            + " sourceRMS=\(String(format: "%.5f", pendingSourceRMS / Double(meterCount)))"
            + " sentRMS=\(String(format: "%.5f", pendingEncodedRMS / Double(meterCount)))"
            + " gain=\(String(format: "%.2f", pendingGain / Double(meterCount)))"
        )
        try await commitAudioBuffer()
        pendingAudioSeconds = 0
        pendingSourceRMS = 0
        pendingEncodedRMS = 0
        pendingGain = 0
        pendingMeterCount = 0
      }

      if Self.shouldRotateRealtimeSession(afterAudioSeconds: sessionAudioSeconds)
        || startedAt.duration(to: .now) >= .seconds(Int(Self.proactiveRealtimeSessionRotationSeconds))
      {
        if pendingAudioSeconds >= 0.2 {
          log("rotation commit session=\(sessionIndex) pendingSeconds=\(String(format: "%.2f", pendingAudioSeconds))")
          try await commitAudioBuffer()
        }
        return SessionAudioResult(shouldRotate: true, audioSecondsSent: sessionAudioSeconds)
      }
    }

    log("audio stream ended appendCount=\(appendCount) pendingSeconds=\(String(format: "%.2f", pendingAudioSeconds))")
    if pendingAudioSeconds >= 0.2 {
      log("final commit pendingSeconds=\(String(format: "%.2f", pendingAudioSeconds))")
      try await commitAudioBuffer()
    }
    try? await Task.sleep(for: .milliseconds(1_500))
    return SessionAudioResult(shouldRotate: false, audioSecondsSent: sessionAudioSeconds)
  }

  private func waitForReceiver(_ receiverTask: Task<Void, Error>, sessionIndex: Int) async throws {
    do {
      try await receiverTask.value
    } catch {
      if isExpectedConnectionCloseError(error) {
        log("receiver closed session=\(sessionIndex) reason=\(error.localizedDescription)")
        return
      }
      throw error
    }
  }

  private func receiveEvents(
    onTranscript: @escaping @Sendable (RealtimeTranscriptionResult) async -> Void
  ) async throws {
    while !Task.isCancelled {
      let message = try await receiveMessage()
      guard case let .string(text) = message else {
        continue
      }

      try await handleEventText(text, onTranscript: onTranscript)
    }
  }

  private func handleEventText(
    _ text: String,
    onTranscript: @escaping @Sendable (RealtimeTranscriptionResult) async -> Void
  ) async throws {
    guard let data = text.data(using: .utf8) else {
      return
    }

    let event = try decoder.decode(ServerEvent.self, from: data)
    if event.type != "session.created" {
      log("event type=\(event.type) item=\(event.itemID ?? "") delta=\(event.delta?.prefix(24) ?? "") transcript=\(event.transcript?.prefix(24) ?? "")")
    } else {
      log("event type=session.created")
    }
    switch event.type {
    case "input_audio_buffer.speech_started":
      if let itemID = event.itemID {
        var timing = itemTimingByID[itemID] ?? ItemTiming()
        timing.startMS = event.audioStartMS
        itemTimingByID[itemID] = timing
      }
    case "input_audio_buffer.speech_stopped":
      if let itemID = event.itemID {
        var timing = itemTimingByID[itemID] ?? ItemTiming()
        timing.endMS = event.audioEndMS
        itemTimingByID[itemID] = timing
      }
    case "conversation.item.input_audio_transcription.completed":
      guard let transcript = event.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty else {
        return
      }

      let itemID = event.itemID ?? event.eventID ?? UUID().uuidString
      let timing = itemTimingByID[itemID]
      let hasTiming = timing?.startMS != nil || timing?.endMS != nil
      let startSeconds: Double
      let durationSeconds: Double
      if hasTiming {
        let sessionStartSeconds = Double(timing?.startMS ?? 0) / 1_000
        let sessionEndSeconds = Double(timing?.endMS ?? timing?.startMS ?? 0) / 1_000
        startSeconds = currentSessionAudioOffsetSeconds + sessionStartSeconds
        durationSeconds = max(0, sessionEndSeconds - sessionStartSeconds)
      } else {
        startSeconds = fallbackNextStartSeconds
        durationSeconds = Self.commitIntervalSeconds
        fallbackNextStartSeconds += durationSeconds
      }
      completedSequence += 1
      deltaTextByItemID[itemID] = nil
      let result = RealtimeTranscriptionResult(
        id: itemID.isEmpty ? "realtime-completed-\(completedSequence)" : itemID,
        startSeconds: startSeconds,
        durationSeconds: durationSeconds,
        text: transcript
      )
      await onTranscript(result)
    case "conversation.item.input_audio_transcription.delta", "transcript.text.delta":
      guard let delta = event.delta, !delta.isEmpty else {
        return
      }
      let itemID = event.itemID ?? "realtime-streaming"
      let itemText = (deltaTextByItemID[itemID] ?? "") + delta
      deltaTextByItemID[itemID] = itemText
      let previewText = appendDeduplicated(itemText, to: streamingTranscript)
      await onTranscript(RealtimeTranscriptionResult(
        id: "realtime-streaming",
        startSeconds: 0,
        durationSeconds: 0,
        text: previewText
      ))
    case "transcript.text.done":
      let completedText = event.transcript ?? event.text
      if let transcript = completedText?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
        streamingTranscript = transcript
      }
      guard !streamingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }
      await onTranscript(RealtimeTranscriptionResult(
        id: "realtime-streaming",
        startSeconds: 0,
        durationSeconds: 0,
        text: streamingTranscript
      ))
    case "error":
      let message = event.error?.message ?? "Realtime transcription failed."
      let code = event.error?.code.map { " [\($0)]" } ?? ""
      log("event error message=\(message)\(code)")
      throw WalleBrainError.invalidResponse("\(message)\(code)")
    default:
      return
    }
  }

  private func sendJSON(_ payload: [String: Any]) async throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    guard let text = String(data: data, encoding: .utf8) else {
      throw WalleBrainError.invalidResponse("Realtime transcription payload could not be encoded.")
    }
    try await sendMessage(.string(text))
  }

  private func commitAudioBuffer() async throws {
    try await sendJSON(["type": "input_audio_buffer.commit"])
  }

  private func appendDeduplicated(_ incoming: String, to existing: String) -> String {
    let incoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
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

    return existing + incoming
  }

  private func log(_ message: String) {
    guard let debugLogURL else {
      return
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"
    do {
      try FileManager.default.createDirectory(
        at: debugLogURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      if FileManager.default.fileExists(atPath: debugLogURL.path(percentEncoded: false)) {
        let handle = try FileHandle(forWritingTo: debugLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
      } else {
        try line.write(to: debugLogURL, atomically: true, encoding: .utf8)
      }
    } catch {
      // Best-effort realtime diagnostics only.
    }
  }

  private func sendMessage(_ message: URLSessionWebSocketTask.Message) async throws {
    guard let webSocketTask else {
      throw WalleBrainError.invalidResponse("Realtime transcription connection is not open.")
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      webSocketTask.send(message) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func receiveMessage() async throws -> URLSessionWebSocketTask.Message {
    guard let webSocketTask else {
      throw WalleBrainError.invalidResponse("Realtime transcription connection is not open.")
    }

    return try await withCheckedThrowingContinuation { continuation in
      webSocketTask.receive { result in
        switch result {
        case let .success(message):
          continuation.resume(returning: message)
        case let .failure(error):
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func isExpectedConnectionCloseError(_ error: Error) -> Bool {
    let description = error.localizedDescription.lowercased()
    return description.contains("cancelled")
      || description.contains("socket is not connected")
      || description.contains("socket not connected")
      || description.contains("network connection was lost")
      || description.contains("realtime transcription connection is not open")
      || description.contains("session_expired")
      || description.contains("maximum duration")
  }

  private static func encodedPCM16Audio(from buffer: AVAudioPCMBuffer) -> EncodedAudio? {
    let pcm16Buffer: AVAudioPCMBuffer
    if buffer.format.commonFormat == audioFormat.commonFormat
      && buffer.format.sampleRate == audioFormat.sampleRate
      && buffer.format.channelCount == audioFormat.channelCount
      && buffer.format.isInterleaved == audioFormat.isInterleaved
    {
      pcm16Buffer = buffer
    } else if let converted = AudioPCMBufferFormatConverter.convert(buffer, to: audioFormat) {
      pcm16Buffer = converted
    } else {
      return nil
    }

    let audioBuffer = pcm16Buffer.audioBufferList.pointee.mBuffers
    guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
      return nil
    }

    var pcmData = Data(bytes: data, count: Int(audioBuffer.mDataByteSize))
    let sourceRMS = rmsLevel(ofPCM16Data: pcmData)
    let gain = gainMultiplier(forRMS: sourceRMS)
    if gain > 1 {
      pcmData.withUnsafeMutableBytes { rawBuffer in
        guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
          return
        }

        let sampleCount = rawBuffer.count / MemoryLayout<Int16>.size
        for index in 0 ..< sampleCount {
          let scaled = Double(samples[index]) * gain
          let clipped = min(Double(Int16.max), max(Double(Int16.min), scaled))
          samples[index] = Int16(clipped)
        }
      }
    }

    return EncodedAudio(
      base64: pcmData.base64EncodedString(),
      rms: rmsLevel(ofPCM16Data: pcmData),
      gain: gain
    )
  }

  private static func gainMultiplier(forRMS rms: Double) -> Double {
    guard rms > 0, rms < 0.10 else {
      return 1
    }

    return min(20, max(1, 0.12 / rms))
  }

  private static func rmsLevel(ofPCM16Data data: Data) -> Double {
    guard data.count >= MemoryLayout<Int16>.size else {
      return 0
    }

    return data.withUnsafeBytes { rawBuffer in
      guard let samples = rawBuffer.bindMemory(to: Int16.self).baseAddress else {
        return 0
      }

      let sampleCount = rawBuffer.count / MemoryLayout<Int16>.size
      guard sampleCount > 0 else {
        return 0
      }

      var total = 0.0
      for index in 0 ..< sampleCount {
        let sample = Double(samples[index]) / Double(Int16.max)
        total += sample * sample
      }
      return sqrt(total / Double(sampleCount))
    }
  }

  private static func durationSeconds(of buffer: AVAudioPCMBuffer) -> Double {
    guard buffer.format.sampleRate > 0 else {
      return 0
    }
    return Double(buffer.frameLength) / buffer.format.sampleRate
  }

  private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Double {
    guard buffer.frameLength > 0 else {
      return 0
    }

    if let channels = buffer.floatChannelData {
      var total = 0.0
      var count = 0
      for channel in 0 ..< Int(buffer.format.channelCount) {
        let pointer = channels[channel]
        for frame in 0 ..< Int(buffer.frameLength) {
          let sample = Double(pointer[frame])
          total += sample * sample
          count += 1
        }
      }
      return count > 0 ? sqrt(total / Double(count)) : 0
    }

    if let channels = buffer.int16ChannelData {
      var total = 0.0
      var count = 0
      for channel in 0 ..< Int(buffer.format.channelCount) {
        let pointer = channels[channel]
        for frame in 0 ..< Int(buffer.frameLength) {
          let sample = Double(pointer[frame]) / Double(Int16.max)
          total += sample * sample
          count += 1
        }
      }
      return count > 0 ? sqrt(total / Double(count)) : 0
    }

    return 0
  }

  private static func createClientSecret(
    configuration: RealtimeTranscriptionConfiguration,
    prompt: String,
    urlSession: URLSession
  ) async throws -> String {
    guard let url = URL(string: "https://api.openai.com/v1/realtime/client_secrets") else {
      throw WalleBrainError.invalidResponse("Realtime transcription client secret URL is invalid.")
    }

    var transcription: [String: Any] = [
      "model": configuration.model,
      "language": "zh",
    ]
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedPrompt.isEmpty, supportsPrompt(model: configuration.model) {
      transcription["prompt"] = trimmedPrompt
    }
    if requiresManualTurnDetection(model: configuration.model) {
      transcription["delay"] = "low"
    }

    var input: [String: Any] = [
      "format": [
        "type": "audio/pcm",
        "rate": 24_000,
      ],
      "transcription": transcription,
    ]
    if !requiresManualTurnDetection(model: configuration.model) {
      input["noise_reduction"] = [
        "type": "near_field",
      ]
    }
    if requiresManualTurnDetection(model: configuration.model) {
      input["turn_detection"] = NSNull()
    }

    let payload: [String: Any] = [
      "session": [
        "type": "transcription",
        "audio": [
          "input": input,
        ],
      ],
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw WalleBrainError.invalidResponse("Realtime transcription test returned a non-HTTP response.")
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw WalleBrainError.invalidResponse(Self.errorMessage(from: data, statusCode: httpResponse.statusCode))
    }

    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let value = object["value"] as? String,
      !value.isEmpty
    else {
      throw WalleBrainError.invalidResponse("Realtime transcription client secret response did not include a token.")
    }

    return value
  }

  private static func supportsPrompt(model: String) -> Bool {
    !model.lowercased().contains("gpt-realtime-whisper")
  }

  private static func requiresManualTurnDetection(model: String) -> Bool {
    model.lowercased().contains("gpt-realtime-whisper")
  }

  private static func errorMessage(from data: Data, statusCode: Int) -> String {
    if
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      return "Realtime transcription test failed (\(statusCode)): \(message)"
    }

    if let text = String(data: data, encoding: .utf8), !text.isEmpty {
      return "Realtime transcription test failed (\(statusCode)): \(text)"
    }

    return "Realtime transcription test failed with HTTP \(statusCode)."
  }
}
