import type { IncomingMessage, ServerResponse } from "node:http";

import { MeetingOrchestrator } from "../meeting/orchestration/meeting-orchestrator.js";
import { createPostProcessor } from "../meeting/postprocess/post-processor-factory.js";
import type { PostProcessorStrategy } from "../meeting/postprocess/post-processor-factory.js";
import { FakeRecorder } from "../meeting/recorder/fake-recorder.js";
import { FfmpegAvfoundationRecorder } from "../meeting/recorder/real-recorder.js";
import { loadLatestSession } from "../meeting/session/latest-session.js";
import type {
  AudioInputDevice,
  SessionMode,
} from "../meeting/session/session-types.js";

type RequestHandlerResult = {
  statusCode: number;
  body: unknown;
};

type RunSessionRequest = {
  title?: string;
  mode?: SessionMode;
  processor?: PostProcessorStrategy;
};

type StartLiveSessionRequest = {
  title?: string;
  mode?: SessionMode;
  processor?: PostProcessorStrategy;
  audioDeviceIndex?: string;
  audioDeviceName?: string;
  dictationEnabled?: boolean;
};

type StopLiveSessionRequest = {
  sessionJsonPath?: string;
  processor?: PostProcessorStrategy;
};

type SyncTranscriptRequest = {
  sessionJsonPath?: string;
  transcriptText?: string;
};

type ReprocessLatestRequest = {
  processor?: PostProcessorStrategy;
};

let mutationInFlight = false;
let activeLiveSessionJsonPath: string | null = null;

const fakeRecorder = new FakeRecorder();
const realRecorder = new FfmpegAvfoundationRecorder();

function isSessionMode(value: unknown): value is SessionMode {
  return value === "normal" || value === "important";
}

function isPostProcessorStrategy(value: unknown): value is PostProcessorStrategy {
  return value === "auto" || value === "fake" || value === "real";
}

async function readJsonBody(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];

  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }

  if (chunks.length === 0) {
    return {};
  }

  const raw = Buffer.concat(chunks).toString("utf8").trim();
  return raw ? JSON.parse(raw) : {};
}

function createOrchestrator(strategy: PostProcessorStrategy): MeetingOrchestrator {
  return new MeetingOrchestrator(
    undefined,
    undefined,
    undefined,
    fakeRecorder,
    createPostProcessor(strategy),
  );
}

function createLiveOrchestrator(strategy: PostProcessorStrategy): MeetingOrchestrator {
  return new MeetingOrchestrator(
    undefined,
    undefined,
    undefined,
    realRecorder,
    createPostProcessor(strategy),
  );
}

async function handleGetLatestSession(baseDir: string): Promise<RequestHandlerResult> {
  const latest = await loadLatestSession(baseDir);
  return {
    statusCode: 200,
    body: {
      ok: true,
      sourcePath: latest.sourcePath,
      session: latest.session,
    },
  };
}

async function handleRunSession(
  baseDir: string,
  payload: RunSessionRequest,
): Promise<RequestHandlerResult> {
  return runExclusiveMutation(async () => {
    const processor = isPostProcessorStrategy(payload.processor) ? payload.processor : "auto";
    const orchestrator = createOrchestrator(processor);
    const result = await orchestrator.runFakeHarness({
      title: payload.title?.trim() || "Meeting Harness Run",
      mode: isSessionMode(payload.mode) ? payload.mode : "normal",
      baseDir,
    });

    return {
      statusCode: 200,
      body: {
        ok: true,
        sourcePath: result.session.paths.sessionJson,
        session: result.session,
        provider: result.postProcessResult.provider,
        model: result.postProcessResult.model,
      },
    };
  });
}

async function handleListAudioDevices(): Promise<RequestHandlerResult> {
  const devices = await realRecorder.listAudioInputDevices();
  return {
    statusCode: 200,
    body: {
      ok: true,
      devices,
      activeLiveSessionJsonPath,
    },
  };
}

async function handleStartLiveSession(
  baseDir: string,
  payload: StartLiveSessionRequest,
): Promise<RequestHandlerResult> {
  return runExclusiveMutation(async () => {
    if (activeLiveSessionJsonPath) {
      throw new Error("A live session is already recording. Stop it before starting another one.");
    }

    const processor = isPostProcessorStrategy(payload.processor) ? payload.processor : "auto";
    const orchestrator = createLiveOrchestrator(processor);
    const audioDevice = payload.audioDeviceIndex
      ? {
        kind: "avfoundation",
        index: payload.audioDeviceIndex,
        name: payload.audioDeviceName?.trim() || `Audio Device ${payload.audioDeviceIndex}`,
      } satisfies AudioInputDevice
      : null;

    const session = await orchestrator.startLiveSession({
      title: payload.title?.trim() || "Live Meeting Session",
      mode: isSessionMode(payload.mode) ? payload.mode : "normal",
      baseDir,
      audioDevice,
      recorderType: "ffmpeg-avfoundation",
      dictationEnabled: typeof payload.dictationEnabled === "boolean" ? payload.dictationEnabled : true,
      recordingEnabled: true,
    });

    activeLiveSessionJsonPath = session.paths.sessionJson;

    return {
      statusCode: 200,
      body: {
        ok: true,
        sourcePath: session.paths.sessionJson,
        session,
      },
    };
  });
}

async function handleStopLiveSession(
  baseDir: string,
  payload: StopLiveSessionRequest,
): Promise<RequestHandlerResult> {
  return runExclusiveMutation(async () => {
    const sessionJsonPath = payload.sessionJsonPath ?? activeLiveSessionJsonPath;

    if (!sessionJsonPath) {
      throw new Error("No active live session is currently being tracked.");
    }

    const processor = isPostProcessorStrategy(payload.processor) ? payload.processor : "auto";
    const orchestrator = createLiveOrchestrator(processor);

    try {
      const result = await orchestrator.stopLiveSession(sessionJsonPath);
      activeLiveSessionJsonPath = null;

      return {
        statusCode: 200,
        body: {
          ok: true,
          sourcePath: result.session.paths.sessionJson,
          session: result.session,
          provider: result.postProcessResult.provider,
          model: result.postProcessResult.model,
        },
      };
    } catch (error) {
      if (error instanceof Error && error.message.includes("No active recorder")) {
        activeLiveSessionJsonPath = null;
      }
      throw error;
    }
  });
}

async function handleSyncTranscript(
  baseDir: string,
  payload: SyncTranscriptRequest,
): Promise<RequestHandlerResult> {
  return runExclusiveMutation(async () => {
    const sessionJsonPath = payload.sessionJsonPath ?? activeLiveSessionJsonPath;

    if (!sessionJsonPath) {
      throw new Error("No live session is available for transcript sync.");
    }

    const orchestrator = createLiveOrchestrator("auto");
    const session = await orchestrator.syncLiveTranscript(
      sessionJsonPath,
      payload.transcriptText?.trim() ?? "",
    );

    return {
      statusCode: 200,
      body: {
        ok: true,
        sourcePath: session.paths.sessionJson,
        session,
      },
    };
  });
}

async function handleReprocessLatest(
  baseDir: string,
  payload: ReprocessLatestRequest,
): Promise<RequestHandlerResult> {
  return runExclusiveMutation(async () => {
    const latest = await loadLatestSession(baseDir);
    const processor = isPostProcessorStrategy(payload.processor) ? payload.processor : "auto";
    const orchestrator = createOrchestrator(processor);
    const result = await orchestrator.rerunPostProcess(latest.sourcePath);

    return {
      statusCode: 200,
      body: {
        ok: true,
        sourcePath: result.session.paths.sessionJson,
        session: result.session,
        provider: result.postProcessResult.provider,
        model: result.postProcessResult.model,
      },
    };
  });
}

export async function handleSessionDevRequest(
  request: IncomingMessage,
  baseDir: string,
): Promise<RequestHandlerResult | null> {
  const requestUrl = new URL(request.url ?? "/", "http://127.0.0.1");

  if (request.method === "GET" && requestUrl.pathname === "/api/audio/devices") {
    return handleListAudioDevices();
  }

  if (request.method === "GET" && requestUrl.pathname === "/api/session/latest") {
    return handleGetLatestSession(baseDir);
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/session/run") {
    const payload = await readJsonBody(request) as RunSessionRequest;
    return handleRunSession(baseDir, payload);
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/session/start-live") {
    const payload = await readJsonBody(request) as StartLiveSessionRequest;
    return handleStartLiveSession(baseDir, payload);
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/session/stop-live") {
    const payload = await readJsonBody(request) as StopLiveSessionRequest;
    return handleStopLiveSession(baseDir, payload);
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/session/sync-transcript") {
    const payload = await readJsonBody(request) as SyncTranscriptRequest;
    return handleSyncTranscript(baseDir, payload);
  }

  if (request.method === "POST" && requestUrl.pathname === "/api/session/reprocess-latest") {
    const payload = await readJsonBody(request) as ReprocessLatestRequest;
    return handleReprocessLatest(baseDir, payload);
  }

  return null;
}

export async function writeJsonResponse(
  response: ServerResponse,
  handler: () => Promise<RequestHandlerResult | null>,
): Promise<void> {
  try {
    const result = await handler();

    if (!result) {
      response.statusCode = 404;
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify({
        ok: false,
        error: "Not found",
      }));
      return;
    }

    response.statusCode = result.statusCode;
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify(result.body));
  } catch (error) {
    response.statusCode = error instanceof Error && error.message.includes("already in progress") ? 409 : 500;
    response.setHeader("Content-Type", "application/json");
    response.end(JSON.stringify({
      ok: false,
      error: error instanceof Error ? error.message : String(error),
    }));
  }
}

export async function runExclusiveMutation<T>(
  action: () => Promise<T>,
): Promise<T> {
  if (mutationInFlight) {
    throw new Error("Another session mutation is already in progress.");
  }

  mutationInFlight = true;

  try {
    return await action();
  } finally {
    mutationInFlight = false;
  }
}
