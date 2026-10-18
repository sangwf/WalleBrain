import AVFoundation
import Foundation

/// Writes capture buffers to an AAC file. Not thread-safe: call it from one serial queue.
///
/// A write failure closes the file and stops further writes instead of throwing, so a broken
/// recording never interrupts the live stream (or the other channel's recording).
final class AudioBufferFileWriter {
  let url: URL
  private var file: AVAudioFile?
  private(set) var framesWritten: AVAudioFramePosition = 0
  private(set) var failure: Error?

  init(url: URL, format: AVAudioFormat) throws {
    self.url = url
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: Int(format.channelCount),
    ]
    file = try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
  }

  func write(_ buffer: AVAudioPCMBuffer) {
    guard let file, buffer.frameLength > 0 else {
      return
    }

    do {
      try file.write(from: buffer)
      framesWritten += AVAudioFramePosition(buffer.frameLength)
    } catch {
      failure = error
      close()
    }
  }

  /// Flushes and closes the file; safe to call more than once.
  func close() {
    file?.close()
    file = nil
  }
}
