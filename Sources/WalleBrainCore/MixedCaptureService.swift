import AVFoundation
import CoreMedia
import Foundation
import Speech

public final class MixedCaptureService: @unchecked Sendable {
  private enum Source {
    case microphone
    case system
  }

  private struct QueuedInput {
    let input: AnalyzerInput
    let receivedAt: Date
  }

  private let microphoneRecorder = MicrophoneCaptureService()
  private let systemAudioRecorder = SystemAudioCaptureService()
  private let callbackQueue = DispatchQueue(label: "com.wallebrain.capture.mixed")
  private let gracePeriod: TimeInterval = 0.08
  private let fileFlushTimeout: TimeInterval = 8.0

  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var configuredFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!
  private var outputURL: URL?
  private var nextBufferStartTime: CMTime?
  private var microphoneTask: Task<Void, Never>?
  private var systemTask: Task<Void, Never>?
  private var microphoneQueue: [QueuedInput] = []
  private var systemQueue: [QueuedInput] = []
  private var temporaryFiles: [URL] = []

  public func start(
    microphoneDevice: AudioInputDevice,
    systemAudioDevice: AudioInputDevice,
    outputURL: URL,
    targetFormat: AVAudioFormat
  ) async throws -> StartedCapture {
    try await stop()

    configuredFormat = targetFormat
    self.outputURL = outputURL
    nextBufferStartTime = .zero

    if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let microphoneTemp = temporaryURL(for: outputURL, suffix: "mic")
    let systemTemp = temporaryURL(for: outputURL, suffix: "system")
    temporaryFiles = [microphoneTemp, systemTemp]

    for url in temporaryFiles where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try FileManager.default.removeItem(at: url)
    }

    let stream = AsyncStream<AnalyzerInput> { continuation in
      self.callbackQueue.async {
        self.continuation = continuation
      }
    }

    do {
      let microphoneCapture = try await microphoneRecorder.start(
        device: microphoneDevice,
        outputURL: microphoneTemp,
        targetFormat: targetFormat
      )
      let systemCapture = try await systemAudioRecorder.start(
        device: systemAudioDevice,
        outputURL: systemTemp,
        targetFormat: targetFormat
      )

      microphoneTask = Task { [weak self] in
        for await input in microphoneCapture.stream {
          guard let self else {
            return
          }
          self.callbackQueue.async {
            self.enqueueLocked(input, source: .microphone)
          }
        }
      }

      systemTask = Task { [weak self] in
        for await input in systemCapture.stream {
          guard let self else {
            return
          }
          self.callbackQueue.async {
            self.enqueueLocked(input, source: .system)
          }
        }
      }

      return StartedCapture(
        inputDevice: AudioInputCatalog.makeMixedInput(for: microphoneDevice),
        audioFileURL: outputURL,
        audioFormat: configuredFormat,
        stream: stream
      )
    } catch {
      try? await microphoneRecorder.stop()
      try? await systemAudioRecorder.stop()
      callbackQueue.sync {
        continuation?.finish()
        continuation = nil
        microphoneQueue.removeAll()
        systemQueue.removeAll()
      }
      self.outputURL = nil
      nextBufferStartTime = nil
      removeTemporaryFiles()
      throw error
    }
  }

  public func stop() async throws {
    microphoneTask?.cancel()
    systemTask?.cancel()
    microphoneTask = nil
    systemTask = nil

    try? await microphoneRecorder.stop()
    try? await systemAudioRecorder.stop()

    callbackQueue.sync {
      drainLocked(flushAll: true)
      continuation?.finish()
      continuation = nil
      microphoneQueue.removeAll()
      systemQueue.removeAll()
    }

    try finalizeOutputFile()
    outputURL = nil
    nextBufferStartTime = nil
    removeTemporaryFiles()
  }

  private func enqueueLocked(_ input: AnalyzerInput, source: Source) {
    let queuedInput = QueuedInput(input: input, receivedAt: Date())

    switch source {
    case .microphone:
      microphoneQueue.append(queuedInput)
    case .system:
      systemQueue.append(queuedInput)
    }

    drainLocked(flushAll: false)
  }

  private func drainLocked(flushAll: Bool) {
    while true {
      if let microphone = microphoneQueue.first, let system = systemQueue.first {
        microphoneQueue.removeFirst()
        systemQueue.removeFirst()
        emitLocked(microphone: microphone, system: system)
        continue
      }

      let now = Date()

      if let microphone = microphoneQueue.first, (flushAll || now.timeIntervalSince(microphone.receivedAt) >= gracePeriod) {
        microphoneQueue.removeFirst()
        emitLocked(single: microphone)
        continue
      }

      if let system = systemQueue.first, (flushAll || now.timeIntervalSince(system.receivedAt) >= gracePeriod) {
        systemQueue.removeFirst()
        emitLocked(single: system)
        continue
      }

      break
    }
  }

  private func emitLocked(microphone: QueuedInput, system: QueuedInput) {
    guard let mixedBuffer = AudioPCMBufferMixer.mix(microphone.input.buffer, system.input.buffer, format: configuredFormat) else {
      return
    }

    let _ = earliestTimestamp(microphone.input.bufferStartTime, system.input.bufferStartTime)
    writeAndYieldLocked(buffer: mixedBuffer)
  }

  private func emitLocked(single queuedInput: QueuedInput) {
    guard let copiedBuffer = AudioPCMBufferMixer.copy(queuedInput.input.buffer) else {
      return
    }

    let _ = queuedInput.input.bufferStartTime
    writeAndYieldLocked(buffer: copiedBuffer)
  }

  private func writeAndYieldLocked(buffer: AVAudioPCMBuffer) {
    let timestamp = nextMonotonicTimestamp(for: buffer)
    continuation?.yield(AnalyzerInput(buffer: buffer, bufferStartTime: timestamp))
  }

  private func finalizeOutputFile() throws {
    guard let outputURL else {
      return
    }

    let fileManager = FileManager.default
    let existingSources = waitForAvailableSources(fileManager: fileManager)

    guard let bestSource = try bestAvailableSource(from: existingSources) else {
      return
    }

    if fileManager.fileExists(atPath: outputURL.path(percentEncoded: false)) {
      try fileManager.removeItem(at: outputURL)
    }

    try fileManager.copyItem(at: bestSource, to: outputURL)
  }

  private func waitForAvailableSources(fileManager: FileManager) -> [URL] {
    let deadline = Date().addingTimeInterval(fileFlushTimeout)

    repeat {
      let available = temporaryFiles.filter { url in
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
          return false
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
      }

      if !available.isEmpty {
        return available
      }

      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline

    return temporaryFiles.filter { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
  }

  private func bestAvailableSource(from candidates: [URL]) throws -> URL? {
    var bestURL: URL?
    var bestSize: Int64 = -1

    for candidate in candidates {
      let values = try candidate.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
      let size = Int64(values.fileSize ?? 0)
      let creationDate = values.creationDate ?? .distantPast
      let bestDate: Date
      if let bestURL {
        bestDate = try bestURL.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast
      } else {
        bestDate = .distantPast
      }

      if size > bestSize || (size == bestSize && creationDate > bestDate) {
        bestURL = candidate
        bestSize = size
      }
    }

    return bestSize > 0 ? bestURL : candidates.first
  }

  private func removeTemporaryFiles() {
    for url in temporaryFiles where FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
      try? FileManager.default.removeItem(at: url)
    }
    temporaryFiles.removeAll()
  }

  private func temporaryURL(for outputURL: URL, suffix: String) -> URL {
    let base = outputURL.deletingPathExtension()
    return base.deletingLastPathComponent()
      .appending(path: "\(base.lastPathComponent).\(suffix).caf", directoryHint: .notDirectory)
  }

  private func earliestTimestamp(_ lhs: CMTime?, _ rhs: CMTime?) -> CMTime? {
    switch (lhs, rhs) {
    case let (.some(lhs), .some(rhs)):
      return lhs <= rhs ? lhs : rhs
    case let (.some(lhs), .none):
      return lhs
    case let (.none, .some(rhs)):
      return rhs
    case (.none, .none):
      return nil
    }
  }

  private func nextMonotonicTimestamp(for buffer: AVAudioPCMBuffer) -> CMTime {
    let start = nextBufferStartTime ?? .zero
    let duration = CMTime(
      seconds: Double(buffer.frameLength) / configuredFormat.sampleRate,
      preferredTimescale: CMTimeScale(configuredFormat.sampleRate.rounded())
    )
    nextBufferStartTime = start + duration
    return start
  }
}
