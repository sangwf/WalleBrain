import type {
  AudioArtifact,
  AudioInputDevice,
  MeetingSession,
} from "../session/session-types.js";

export interface DeviceAwareRecorder {
  listAudioInputDevices(): Promise<AudioInputDevice[]>;
}

export interface Recorder {
  start(session: MeetingSession): Promise<void>;
  stop(session: MeetingSession): Promise<AudioArtifact>;
}
