import { FakeDictationBridge } from "../dictation/fake-dictation-bridge.js";
import type { DictationBridge } from "../dictation/dictation-bridge.js";
import { MarkdownNoteExporter } from "../export/note-exporter.js";
import { SessionLauncher } from "../launcher/session-launcher.js";
import { FakePostProcessor } from "../postprocess/fake-post-processor.js";
import type { PostProcessor } from "../postprocess/post-processor.js";
import { FakeRecorder } from "../recorder/fake-recorder.js";
import type { Recorder } from "../recorder/recorder.js";
import { SessionStore } from "../session/session-store.js";
import type {
  CreateSessionInput,
  MeetingSession,
  PostProcessResult,
} from "../session/session-types.js";

type HarnessRunResult = {
  session: MeetingSession;
  postProcessResult: PostProcessResult;
};

export class MeetingOrchestrator {
  constructor(
    private readonly sessionLauncher = new SessionLauncher(),
    private readonly sessionStore = new SessionStore(),
    private readonly dictationBridge: DictationBridge = new FakeDictationBridge(),
    private readonly recorder: Recorder = new FakeRecorder(),
    private readonly postProcessor: PostProcessor = new FakePostProcessor(),
    private readonly noteExporter = new MarkdownNoteExporter(),
  ) {}

  async createSession(input: CreateSessionInput): Promise<MeetingSession> {
    const session = this.sessionLauncher.createSession(input);
    await this.sessionStore.save(session);
    return session;
  }

  async startLiveSession(input: CreateSessionInput): Promise<MeetingSession> {
    const session = await this.createSession({
      ...input,
      dictationEnabled: input.dictationEnabled ?? false,
      recorderType: input.recorderType ?? "ffmpeg-avfoundation",
    });

    try {
      session.status = "recording";
      await this.recorder.start(session);
      await this.sessionStore.save(session);
      return session;
    } catch (error) {
      session.status = "failed";
      session.errors.push({
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });
      await this.sessionStore.save(session);
      throw error;
    }
  }

  async stopLiveSession(sessionJsonPath: string): Promise<HarnessRunResult> {
    const session = await this.sessionStore.load(sessionJsonPath);

    try {
      const audioArtifact = await this.recorder.stop(session);
      session.paths.audioFile = audioArtifact.path;
      session.endedAt = audioArtifact.endedAt;
      session.status = "recorded";
      await this.sessionStore.save(session);

      return this.finishPostProcessAndExport(session);
    } catch (error) {
      session.status = "failed";
      session.processing.transcriptStatus = "failed";
      session.processing.summaryStatus = "failed";
      session.processing.exportStatus = "failed";
      session.errors.push({
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });
      await this.sessionStore.save(session);
      throw error;
    }
  }

  async rerunPostProcess(sessionJsonPath: string): Promise<HarnessRunResult> {
    const session = await this.sessionStore.load(sessionJsonPath);

    try {
      return this.finishPostProcessAndExport(session);
    } catch (error) {
      session.status = "failed";
      session.processing.transcriptStatus = "failed";
      session.processing.summaryStatus = "failed";
      session.processing.exportStatus = "failed";
      session.errors.push({
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });
      await this.sessionStore.save(session);
      throw error;
    }
  }

  async runFakeHarness(input: CreateSessionInput): Promise<HarnessRunResult> {
    const session = await this.createSession(input);

    try {
      session.status = "recording";
      await this.sessionStore.save(session);

      await this.recorder.start(session);
      await this.dictationBridge.run(session, async (chunk) => {
        session.artifacts.liveTranscriptChunks.push(chunk.text);
        await this.sessionStore.save(session);
      });

      const audioArtifact = await this.recorder.stop(session);
      session.paths.audioFile = audioArtifact.path;
      session.endedAt = audioArtifact.endedAt;
      session.status = "recorded";
      await this.sessionStore.save(session);
      return this.finishPostProcessAndExport(session);
    } catch (error) {
      session.status = "failed";
      session.errors.push({
        at: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      });
      await this.sessionStore.save(session);
      throw error;
    }
  }

  async syncLiveTranscript(sessionJsonPath: string, transcriptText: string): Promise<MeetingSession> {
    const session = await this.sessionStore.load(sessionJsonPath);
    session.artifacts.liveTranscriptChunks = transcriptText
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);
    await this.sessionStore.save(session);
    return session;
  }

  private async finishPostProcessAndExport(session: MeetingSession): Promise<HarnessRunResult> {
    session.status = "transcribing";
    session.processing.transcriptStatus = "running";
    session.processing.summaryStatus = "running";
    session.processing.exportStatus = "pending";
    await this.sessionStore.save(session);

    const postProcessResult = await this.postProcessor.run(session);
    session.artifacts.transcript = postProcessResult.transcript;
    session.artifacts.summary = postProcessResult.summary;
    session.artifacts.keyPoints = postProcessResult.keyPoints;
    session.artifacts.actionItems = postProcessResult.actionItems;
    session.processing.transcriptStatus = "completed";
    session.processing.summaryStatus = "completed";
    session.status = "summarized";
    await this.sessionStore.save(session);

    session.processing.exportStatus = "running";
    await this.sessionStore.save(session);
    const exportResult = await this.noteExporter.export(session, postProcessResult);
    session.paths.finalNote = exportResult.path;
    session.processing.exportStatus = "completed";
    session.status = "exported";
    await this.sessionStore.save(session);

    return {
      session,
      postProcessResult,
    };
  }
}
