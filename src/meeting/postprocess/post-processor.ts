import type {
  MeetingSession,
  PostProcessResult,
} from "../session/session-types.js";

export interface PostProcessor {
  run(session: MeetingSession): Promise<PostProcessResult>;
}

