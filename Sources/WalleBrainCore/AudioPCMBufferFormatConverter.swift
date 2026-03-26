import AVFoundation
import Foundation

enum AudioPCMBufferFormatConverter {
  static func convert(
    _ sourceBuffer: AVAudioPCMBuffer,
    to targetFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    if formatsMatch(sourceBuffer.format, targetFormat) {
      return sourceBuffer
    }

    guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
      return nil
    }

    let frameCount = Int(sourceBuffer.frameLength)
    let targetCapacity = max(
      1,
      AVAudioFrameCount(
        ceil(Double(frameCount) * targetFormat.sampleRate / sourceBuffer.format.sampleRate) + 32
      )
    )
    guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
      return nil
    }

    var didProvideSource = false
    var conversionError: NSError?
    let conversionStatus = converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
      if didProvideSource {
        outStatus.pointee = .endOfStream
        return nil
      }

      didProvideSource = true
      outStatus.pointee = .haveData
      return sourceBuffer
    }

    guard conversionError == nil else {
      return nil
    }

    switch conversionStatus {
    case .haveData, .inputRanDry, .endOfStream:
      return targetBuffer.frameLength > 0 ? targetBuffer : nil
    case .error:
      return nil
    @unknown default:
      return nil
    }
  }

  private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.commonFormat == rhs.commonFormat
      && lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.isInterleaved == rhs.isInterleaved
  }
}
