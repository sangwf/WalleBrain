import type { MeetingSession } from "../session/session-types.js";
import type { DictationBridge, LiveChunkHandler } from "./dictation-bridge.js";

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

export class FakeDictationBridge implements DictationBridge {
  constructor(
    private readonly chunks: string[] = [
      "今天先把会议助手的 harness 跑通，重点不是识别精度，而是链路稳定。",
      "第一阶段先用系统 Dictation 作为实时参考，正式稿交给会后批处理。",
      "session.md 和 session.json 要先稳定下来，后面模块都挂在这两个契约上。",
      "今天的输出目标是能生成最终 note，并且后续模块可替换。",
    ],
    private readonly delayMs = 50,
  ) {}

  async run(session: MeetingSession, onChunk: LiveChunkHandler): Promise<void> {
    if (!session.features.dictationEnabled) {
      return;
    }

    for (const text of this.chunks) {
      await sleep(this.delayMs);
      await onChunk({
        at: new Date().toISOString(),
        text,
      });
    }
  }
}

