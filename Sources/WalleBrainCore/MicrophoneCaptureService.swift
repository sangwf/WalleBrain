import AVFoundation
import CoreMedia
import Foundation
import Speech

public struct StartedCapture {
  public let inputDevice: AudioInputDevice
  public let audioFileURL: URL
  public let audioFormat: AVAudioFormat
  public let stream: AsyncStream<AnalyzerInput>
}

public final class MicrophoneCaptureService: NSObject, @unchecked Sendable {
  private let captureSession = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private let fileOutput = AVCaptureAudioFileOutput()
  private let callbackQueue = DispatchQueue(label: "com.wallebrain.capture.audio")

  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var configuredFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!
  private var stopRecordingContinuation: CheckedContinuation<Void, Error>?

  public func start(
    device: AudioInputDevice,
    outputURL: URL,
    targetFormat: AVAudioFormat
  ) async throws -> StartedCapture {
    try await stop()

    guard let avDevice = AudioInputCatalog.device(for: device.id) else {
      throw WalleBrainError.invalidResponse("Input device disappeared: \(device.name)")
    }

    configuredFormat = targetFormat

    let stream = AsyncStream<AnalyzerInput> { continuation in
      self.continuation = continuation
    }

    do {
      if FileManager.default.fileExists(atPath: outputURL.path(percentEncoded: false)) {
        try FileManager.default.removeItem(at: outputURL)
      }
      try configureSession(device: avDevice)
      captureSession.startRunning()
      fileOutput.startRecording(to: outputURL, outputFileType: .caf, recordingDelegate: self)
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
    output.setSampleBufferDelegate(nil, queue: nil)
    if fileOutput.isRecording {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        callbackQueue.async {
          self.stopRecordingContinuation = continuation
          self.fileOutput.stopRecording()
        }
      }
    }
    if captureSession.isRunning {
      captureSession.stopRunning()
    }
    continuation?.finish()
    continuation = nil
  }

  private func configureSession(device: AVCaptureDevice) throws {
    captureSession.beginConfiguration()
    defer { captureSession.commitConfiguration() }

    for input in captureSession.inputs {
      captureSession.removeInput(input)
    }
    for output in captureSession.outputs {
      captureSession.removeOutput(output)
    }

    let input = try AVCaptureDeviceInput(device: device)
    guard captureSession.canAddInput(input) else {
      throw WalleBrainError.invalidResponse("Could not add audio input \(device.localizedName).")
    }
    captureSession.addInput(input)

    guard captureSession.canAddOutput(output) else {
      throw WalleBrainError.invalidResponse("Could not add audio output.")
    }

    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: configuredFormat.sampleRate,
      AVNumberOfChannelsKey: Int(configuredFormat.channelCount),
      AVLinearPCMBitDepthKey: configuredFormat.streamDescription.pointee.mBitsPerChannel,
      AVLinearPCMIsFloatKey: configuredFormat.commonFormat == .pcmFormatFloat32 || configuredFormat.commonFormat == .pcmFormatFloat64,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: !configuredFormat.isInterleaved,
    ]
    output.setSampleBufferDelegate(self, queue: callbackQueue)
    captureSession.addOutput(output)

    guard captureSession.canAddOutput(fileOutput) else {
      throw WalleBrainError.invalidResponse("Could not add audio file output.")
    }
    captureSession.addOutput(fileOutput)
  }
}

extension MicrophoneCaptureService: AVCaptureAudioDataOutputSampleBufferDelegate {
  public func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection,
  ) {
    guard
      let pcmBuffer = AudioSampleBufferConverter.makePCMBuffer(from: sampleBuffer, targetFormat: configuredFormat),
      let continuation
    else {
      return
    }

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    continuation.yield(AnalyzerInput(buffer: pcmBuffer, bufferStartTime: timestamp.isValid ? timestamp : nil))
  }
}

extension MicrophoneCaptureService: AVCaptureFileOutputRecordingDelegate {
  public func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    if let error {
      stopRecordingContinuation?.resume(throwing: error)
    } else {
      stopRecordingContinuation?.resume()
    }
    stopRecordingContinuation = nil
  }
}
