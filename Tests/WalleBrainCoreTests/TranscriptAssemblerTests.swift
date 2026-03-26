import Testing
@testable import WalleBrainCore

struct TranscriptAssemblerTests {
  @Test
  func replacesProgressiveResultsForSameSpan() {
    let assembler = TranscriptAssembler()
    let first = TranscriptChunk(id: "1", startSeconds: 0, durationSeconds: 0.3, text: "你好")
    let second = TranscriptChunk(id: "2", startSeconds: 0, durationSeconds: 0.8, text: "你好，我")
    let third = TranscriptChunk(id: "3", startSeconds: 0, durationSeconds: 1.4, text: "你好，我现在")

    let merged = assembler.merged(
      chunks: assembler.merged(
        chunks: assembler.merged(chunks: [], with: first),
        with: second
      ),
      with: third
    )

    #expect(merged.count == 1)
    #expect(merged.first?.text == "你好，我现在")
    #expect(assembler.liveTranscript(from: merged) == "你好，我现在")
  }

  @Test
  func keepsSeparatedChunks() {
    let assembler = TranscriptAssembler()
    let first = TranscriptChunk(id: "1", startSeconds: 0, durationSeconds: 1.0, text: "第一句")
    let second = TranscriptChunk(id: "2", startSeconds: 2.0, durationSeconds: 0.8, text: "第二句")

    let merged = assembler.merged(
      chunks: assembler.merged(chunks: [], with: first),
      with: second
    )

    #expect(merged.count == 2)
    #expect(assembler.liveTranscript(from: merged) == "第一句\n第二句")
  }

  @Test
  func replacesOverlappingChunkEvenWhenStartMovesSlightly() {
    let assembler = TranscriptAssembler()
    let first = TranscriptChunk(id: "1", startSeconds: 10.0, durationSeconds: 2.0, text: "我现在跟你聊个天")
    let second = TranscriptChunk(id: "2", startSeconds: 10.02, durationSeconds: 3.4, text: "我现在跟你聊个天，我看看你现在是怎么一回事")

    let merged = assembler.merged(
      chunks: assembler.merged(chunks: [], with: first),
      with: second
    )

    #expect(merged.count == 1)
    #expect(merged.first?.text == "我现在跟你聊个天，我看看你现在是怎么一回事")
  }
}
