import AVFoundation
import CoreMedia
import Foundation
import Speech

enum AudioSampleBufferConverter {
  static func makePCMBuffer(
    from sampleBuffer: CMSampleBuffer,
    targetFormat: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frameCount > 0 else {
      return nil
    }

    guard
      let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
      let sourceFormat = AVAudioFormat(streamDescription: streamDescription)
    else {
      return nil
    }

    guard let sourceBuffer = AVAudioPCMBuffer(
      pcmFormat: sourceFormat,
      frameCapacity: AVAudioFrameCount(frameCount)
    ) else {
      return nil
    }

    sourceBuffer.frameLength = sourceBuffer.frameCapacity
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
      sampleBuffer,
      at: 0,
      frameCount: Int32(frameCount),
      into: sourceBuffer.mutableAudioBufferList
    )

    guard status == noErr else {
      return nil
    }

    if formatsMatch(sourceFormat, targetFormat) {
      return sourceBuffer
    }

    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      return nil
    }

    let resampledCapacity = max(
      1,
      AVAudioFrameCount(
        ceil(Double(frameCount) * targetFormat.sampleRate / sourceFormat.sampleRate) + 32
      )
    )
    guard let targetBuffer = AVAudioPCMBuffer(
      pcmFormat: targetFormat,
      frameCapacity: resampledCapacity
    ) else {
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
