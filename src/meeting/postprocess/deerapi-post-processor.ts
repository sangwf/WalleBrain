import { readFile, rm } from "node:fs/promises";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

import {
  DeerApiClient,
  type ChatContentPart,
} from "../llm/deerapi-client.js";
import type {
  MeetingSession,
  PostProcessResult,
} from "../session/session-types.js";
import type { PostProcessor } from "./post-processor.js";

type ParsedModelOutput = {
  transcript?: string;
  summary?: string;
  keyPoints?: string[];
  actionItems?: string[];
};

const execFileAsync = promisify(execFile);

function buildTranscriptSource(session: MeetingSession): string {
  if (session.artifacts.liveTranscriptChunks.length === 0) {
    return "No live transcript chunks were captured.";
  }

  return session.artifacts.liveTranscriptChunks
    .map((chunk, index) => `${index + 1}. ${chunk}`)
    .join("\n");
}

function extractJson(content: string): ParsedModelOutput {
  const fenced = content.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const candidate = fenced ? fenced[1].trim() : content.trim();
  return JSON.parse(candidate) as ParsedModelOutput;
}

function sanitizeStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value
    .map((item) => String(item).trim())
    .filter(Boolean);
}

function isChannelUnavailable(error: unknown): boolean {
  if (!(error instanceof Error)) {
    return false;
  }

  return error.message.includes("无可用渠道");
}

async function buildAudioPart(session: MeetingSession): Promise<ChatContentPart | null> {
  const audioPath = session.paths.audioFile;

  if (!audioPath) {
    return null;
  }

  const wavPath = path.join(
    path.dirname(audioPath),
    `${path.basename(audioPath, path.extname(audioPath))}.transcribe.wav`,
  );

  try {
    await execFileAsync("ffmpeg", [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      audioPath,
      "-ar",
      "16000",
      "-ac",
      "1",
      wavPath,
    ]);

    const audioBytes = await readFile(wavPath);

    return {
      type: "input_audio",
      input_audio: {
        data: audioBytes.toString("base64"),
        format: "wav",
      },
    };
  } finally {
    await rm(wavPath, { force: true }).catch(() => {});
  }
}

export class DeerApiPostProcessor implements PostProcessor {
  private readonly client: DeerApiClient;

  constructor(
    private readonly options: {
      baseUrl: string;
      apiKey: string;
      normalModelChain?: string[];
      importantModelChain?: string[];
    },
  ) {
    this.client = new DeerApiClient({
      baseUrl: options.baseUrl,
      apiKey: options.apiKey,
    });
  }

  async run(session: MeetingSession): Promise<PostProcessResult> {
    const transcriptSource = buildTranscriptSource(session);
    const audioPart = await buildAudioPart(session);
    const modelChain = session.mode === "important"
      ? (this.options.importantModelChain ?? ["gemini-3.1-pro", "gemini-3-flash", "gemini-2.5-flash"])
      : (this.options.normalModelChain ?? ["gemini-3.1-flash", "gemini-3-flash", "gemini-2.5-flash"]);

    const messages = [
      {
        role: "system" as const,
        content: [
          "You are post-processing a meeting transcript for a personal knowledge workflow.",
          "Return valid JSON only.",
          "Schema:",
          "{",
          '  "transcript": "string",',
          '  "summary": "string",',
          '  "keyPoints": ["string"],',
          '  "actionItems": ["string"]',
          "}",
          "Use attached audio as the primary source when present.",
          "Treat any live transcript reference as noisy hints only.",
          "The transcript field must be a verbatim transcript of the spoken words only.",
          "Do not translate, paraphrase, explain, annotate, or append glosses to the transcript.",
          "Do not add parenthetical English translations or extra commands that were not spoken.",
          "For Chinese audio, keep the transcript in simplified Chinese.",
          "If the audio is silent, too short, or unintelligible, say so explicitly instead of inferring content.",
          'In that case, set "transcript" to "[No clear speech detected]" and keep "summary" equally explicit.',
          'When no clear speech is detected, return empty arrays for "keyPoints" and "actionItems".',
          "Keep transcript concise but faithful. Keep keyPoints and actionItems concrete.",
        ].join("\n"),
      },
      {
        role: "user" as const,
        content: [
          {
            type: "text" as const,
            text: [
              `Meeting title: ${session.title}`,
              `Mode: ${session.mode}`,
              `Started at: ${session.startedAt}`,
              `Audio attached: ${audioPart ? "yes" : "no"}`,
              "",
              "Live transcript reference:",
              transcriptSource,
              "",
              "Return valid JSON only.",
            ].join("\n"),
          },
          ...(audioPart ? [audioPart] : []),
        ],
      },
    ];

    const errors: string[] = [];

    for (const model of modelChain) {
      try {
        const response = await this.client.createChatCompletion({
          model,
          messages,
          temperature: 0.1,
        });
        const parsed = extractJson(response.content);

        return {
          provider: "deerapi",
          model: response.model ?? model,
          transcript: String(parsed.transcript ?? transcriptSource).trim(),
          summary: String(parsed.summary ?? "").trim() || `${session.title} 的会后整理已完成。`,
          keyPoints: sanitizeStringArray(parsed.keyPoints),
          actionItems: sanitizeStringArray(parsed.actionItems),
        };
      } catch (error) {
        errors.push(`${model}: ${error instanceof Error ? error.message : String(error)}`);
        if (!isChannelUnavailable(error)) {
          continue;
        }
      }
    }

    throw new Error(`All DeerAPI model attempts failed.\n${errors.join("\n")}`);
  }
}
