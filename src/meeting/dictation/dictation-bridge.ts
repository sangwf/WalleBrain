import type { MeetingSession } from "../session/session-types.js";

export type LiveChunk = {
  at: string;
  text: string;
};

export type LiveChunkHandler = (chunk: LiveChunk) => Promise<void> | void;

export interface DictationBridge {
  run(session: MeetingSession, onChunk: LiveChunkHandler): Promise<void>;
}

