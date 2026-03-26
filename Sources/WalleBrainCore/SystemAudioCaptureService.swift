import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import Speech

public final class SystemAudioCaptureService: NSObject, @unchecked Sendable {
  private let callbackQueue = DispatchQueue(label: "com.wallebrain.capture.system-audio")
  private let debugRawSystemAudioErrors = ProcessInfo.processInfo.environment["WALLEBRAIN_DEBUG_SYSTEM_AUDIO_ERRORS"] == "1"

  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var configuredFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!
  private var stream: SCStream?
  private var stopContinuation: CheckedContinuation<Void, Error>?
  private var nextBufferStartTime: CMTime?

  public func start(
    device: AudioInputDevice,
    outputURL: URL,
    targetFormat: AVAudioFormat
  ) async throws -> StartedCapture {
    try await stop()

    guard let displayID = AudioInputCatalog.displayID(forSystemAudioInput: device.id) else {
      throw WalleBrainError.invalidResponse("System audio device is unavailable.")
    }

    configuredFormat = targetFormat
    nextBufferStartTime = .zero

    let stream = AsyncStream<AnalyzerInput> { continuation in
      self.continuation = continuation
    }

    do {
      if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
        try FileManager.default.removeItem(at: outputURL)
      }

      let shareableContent: SCShareableContent
      do {
        shareableContent = try await SCShareableContent.current
      } catch {
        throw mapSystemAudioPermissionError(error, prefix: "System audio content discovery failed")
      }
      guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) ?? shareableContent.displays.first else {
        throw WalleBrainError.invalidResponse("No display is available for system audio capture.")
      }

      let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
      let configuration = SCStreamConfiguration()
      configuration.width = 2
      configuration.height = 2
      configuration.showsCursor = false
      configuration.capturesAudio = true
      configuration.sampleRate = Int(configuredFormat.sampleRate)
      configuration.channelCount = Int(configuredFormat.channelCount)
      configuration.excludesCurrentProcessAudio = false
      if #available(macOS 15.0, *) {
        configuration.captureMicrophone = false
      }

      let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)
      do {
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
      } catch {
        throw WalleBrainError.invalidResponse("System audio stream output setup failed: \(error.localizedDescription)")
      }

      do {
        try await startCapture(on: scStream)
      } catch {
        throw mapSystemAudioPermissionError(error, prefix: "System audio stream start failed")
      }
      self.stream = scStream

      return StartedCapture(
        inputDevice: device,
        audioFileURL: outputURL,
        audioFormat: configuredFormat,
        stream: stream
      )
    } catch {
      continuation?.finish()
      continuation = nil
      throw error
    }
  }

  public func stop() async throws {
    guard let stream else {
      continuation?.finish()
      continuation = nil
      nextBufferStartTime = nil
      return
    }

    try await stopCapture(on: stream)
    try? stream.removeStreamOutput(self, type: .audio)
    self.stream = nil
    continuation?.finish()
    continuation = nil
    nextBufferStartTime = nil
  }

  private func startCapture(on stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      stream.startCapture { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func stopCapture(on stream: SCStream) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      self.stopContinuation = continuation
      stream.stopCapture { error in
        if let error {
          self.stopContinuation?.resume(throwing: error)
        } else {
          self.stopContinuation?.resume()
        }
        self.stopContinuation = nil
      }
    }
  }

  private func mapSystemAudioPermissionError(_ error: Error, prefix: String) -> WalleBrainError {
    let description = error.localizedDescription
    let nsError = error as NSError
    let lowered = description.lowercased()
    let diagnostic = "\(prefix): [\(nsError.domain) code=\(nsError.code)] \(description)"

    if debugRawSystemAudioErrors {
      return .invalidResponse(diagnostic)
    }

    if lowered.contains("not authorized")
      || lowered.contains("permission")
      || lowered.contains("denied")
    {
      return .invalidResponse("Screen Recording access is required for System Audio. If you just enabled it in System Settings, quit and reopen WalleBrain once.")
    }

    return .invalidResponse(diagnostic)
  }
}

extension SystemAudioCaptureService: SCStreamOutput {
  public func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .audio else {
      return
    }

    guard
      let pcmBuffer = AudioSampleBufferConverter.makePCMBuffer(from: sampleBuffer, targetFormat: configuredFormat),
      let continuation
    else {
      return
    }

    let timestamp = nextMonotonicTimestamp(for: pcmBuffer)
    continuation.yield(AnalyzerInput(buffer: pcmBuffer, bufferStartTime: timestamp))
  }
}

extension SystemAudioCaptureService: SCStreamDelegate {
  public func stream(_ stream: SCStream, didStopWithError error: Error) {
    if let stopContinuation {
      stopContinuation.resume(throwing: error)
      self.stopContinuation = nil
    }
    continuation?.finish()
    continuation = nil
    nextBufferStartTime = nil
    self.stream = nil
  }
}

extension SystemAudioCaptureService {
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
