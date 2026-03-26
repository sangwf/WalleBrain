import type {
  MeetingSession,
  PostProcessResult,
} from "../session/session-types.js";
import type { PostProcessor } from "./post-processor.js";

function uniqueNonEmpty(items: string[]): string[] {
  return [...new Set(items.map((item) => item.trim()).filter(Boolean))];
}

export class FakePostProcessor implements PostProcessor {
  async run(session: MeetingSession): Promise<PostProcessResult> {
    const liveChunks = session.artifacts.liveTranscriptChunks;
    const transcript = liveChunks.length > 0
      ? liveChunks.map((chunk, index) => `${index + 1}. ${chunk}`).join("\n")
      : "No transcript chunks were captured.";

    const keyPoints = uniqueNonEmpty([
      "先证明 meeting harness 的端到端链路可运行。",
      "实时录写使用系统 Dictation，正式稿依赖会后批处理。",
      "session.md 和 session.json 是当前阶段的核心契约。",
    ]);

    const actionItems = uniqueNonEmpty([
      "实现 fake Dictation、Recorder、Post Processor 的可替换接口。",
      "补最小会议工作台 UI，并绑定 session 状态。",
      "下一步替换 fake Post Processor 为真实 Gemini 调用。",
    ]);

    return {
      provider: "fake",
      model: null,
      transcript,
      summary: `${session.title} 聚焦在会议助手 harness 的首条可运行链路，确认先用 fake 模块打通 session、录音占位、后处理和导出。`,
      keyPoints,
      actionItems,
    };
  }
}
