import Foundation

struct TranscriptAssembler {
  private let overlapToleranceSeconds: Double
  private let startToleranceSeconds: Double

  init(
    overlapToleranceSeconds: Double = 0.05,
    startToleranceSeconds: Double = 0.05
  ) {
    self.overlapToleranceSeconds = overlapToleranceSeconds
    self.startToleranceSeconds = startToleranceSeconds
  }

  func merged(chunks: [TranscriptChunk], with incoming: TranscriptChunk) -> [TranscriptChunk] {
    let retained = chunks.filter { existing in
      !shouldReplace(existing: existing, with: incoming)
    }

    return (retained + [incoming]).sorted(by: Self.isOrdered)
  }

  func liveTranscript(from chunks: [TranscriptChunk]) -> String {
    chunks
      .sorted(by: Self.isOrdered)
      .map(\.text)
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private func shouldReplace(existing: TranscriptChunk, with incoming: TranscriptChunk) -> Bool {
    if abs(existing.startSeconds - incoming.startSeconds) <= startToleranceSeconds {
      return true
    }

    let existingStart = existing.startSeconds
    let existingEnd = existing.startSeconds + max(existing.durationSeconds, 0)
    let incomingStart = incoming.startSeconds
    let incomingEnd = incoming.startSeconds + max(incoming.durationSeconds, 0)
    let overlapStart = max(existingStart, incomingStart)
    let overlapEnd = min(existingEnd, incomingEnd)

    return overlapEnd - overlapStart > overlapToleranceSeconds
  }

  private static func isOrdered(_ left: TranscriptChunk, _ right: TranscriptChunk) -> Bool {
    if left.startSeconds == right.startSeconds {
      return left.durationSeconds < right.durationSeconds
    }
    return left.startSeconds < right.startSeconds
  }
}
