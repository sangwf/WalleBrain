import AVFoundation
import Foundation

enum AudioPCMBufferMixer {
  static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard
      let format = AVAudioFormat(
        commonFormat: source.format.commonFormat,
        sampleRate: source.format.sampleRate,
        channels: source.format.channelCount,
        interleaved: source.format.isInterleaved
      ),
      let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameCapacity)
    else {
      return nil
    }

    copy.frameLength = source.frameLength

    if format.commonFormat == .pcmFormatFloat32, let sourceChannels = source.floatChannelData, let targetChannels = copy.floatChannelData {
      for channel in 0 ..< Int(format.channelCount) {
        targetChannels[channel].update(from: sourceChannels[channel], count: Int(source.frameLength))
      }
      return copy
    }

    if format.commonFormat == .pcmFormatInt16, let sourceChannels = source.int16ChannelData, let targetChannels = copy.int16ChannelData {
      for channel in 0 ..< Int(format.channelCount) {
        targetChannels[channel].update(from: sourceChannels[channel], count: Int(source.frameLength))
      }
      return copy
    }

    return nil
  }

  static func mix(_ lhs: AVAudioPCMBuffer, _ rhs: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
    guard format.commonFormat == .pcmFormatFloat32 else {
      return copy(lhs)
    }

    let frameLength = max(lhs.frameLength, rhs.frameLength)
    guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
      return nil
    }

    mixed.frameLength = frameLength

    guard let mixedChannels = mixed.floatChannelData else {
      return nil
    }

    for channel in 0 ..< Int(format.channelCount) {
      let mixedPointer = mixedChannels[channel]
      let lhsPointer = lhs.floatChannelData?[min(channel, Int(lhs.format.channelCount) - 1)]
      let rhsPointer = rhs.floatChannelData?[min(channel, Int(rhs.format.channelCount) - 1)]

      for frame in 0 ..< Int(frameLength) {
        let lhsValue = frame < Int(lhs.frameLength) ? (lhsPointer?[frame] ?? 0) : 0
        let rhsValue = frame < Int(rhs.frameLength) ? (rhsPointer?[frame] ?? 0) : 0
        mixedPointer[frame] = max(-1, min(1, lhsValue + rhsValue))
      }
    }

    return mixed
  }
}
