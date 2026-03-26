import { mkdir, stat } from "node:fs/promises";
import { spawn } from "node:child_process";
import path from "node:path";

import type {
  AudioArtifact,
  AudioInputDevice,
  MeetingSession,
} from "../session/session-types.js";
import type { DeviceAwareRecorder, Recorder } from "./recorder.js";

type ActiveRecording = {
  child: ReturnType<typeof spawn>;
  startedAt: string;
  stderr: string[];
  exitCode: number | null;
  exitSignal: NodeJS.Signals | null;
  exitPromise: Promise<void>;
};

const AUDIO_DEVICE_SECTION = "AVFoundation audio devices:";
const DEVICE_PATTERN = /\[(\d+)\]\s+(.+)$/;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function selectDefaultAudioDevice(devices: AudioInputDevice[]): AudioInputDevice | null {
  if (devices.length === 0) {
    return null;
  }

  const preferredMatch = devices.find((device) => /macbook pro.*麦克风|macbook pro microphone/i.test(device.name));
  return preferredMatch ?? devices[0];
}

async function readAvfoundationAudioDevices(): Promise<AudioInputDevice[]> {
  const child = spawn("ffmpeg", [
    "-hide_banner",
    "-f",
    "avfoundation",
    "-list_devices",
    "true",
    "-i",
    "",
  ], {
    stdio: ["ignore", "ignore", "pipe"],
  });

  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => {
    stderr += chunk;
  });

  await new Promise<void>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", () => resolve());
  });

  const devices: AudioInputDevice[] = [];
  let inAudioSection = false;

  for (const rawLine of stderr.split("\n")) {
    const line = rawLine.trim();

    if (!line) {
      continue;
    }

    if (line.includes(AUDIO_DEVICE_SECTION)) {
      inAudioSection = true;
      continue;
    }

    if (!inAudioSection) {
      continue;
    }

    if (line.includes("Error opening input")) {
      break;
    }

    const match = line.match(DEVICE_PATTERN);

    if (!match) {
      continue;
    }

    devices.push({
      kind: "avfoundation",
      index: match[1],
      name: match[2],
    });
  }

  return devices;
}

export class FfmpegAvfoundationRecorder implements Recorder, DeviceAwareRecorder {
  private readonly activeRecordings = new Map<string, ActiveRecording>();

  async listAudioInputDevices(): Promise<AudioInputDevice[]> {
    return readAvfoundationAudioDevices();
  }

  async start(session: MeetingSession): Promise<void> {
    if (!session.features.recordingEnabled) {
      return;
    }

    if (this.activeRecordings.has(session.id)) {
      throw new Error(`Recording is already running for session ${session.id}.`);
    }

    const targetPath = session.paths.audioFile;

    if (!targetPath) {
      throw new Error("Audio file path is not configured for this session.");
    }

    const availableDevices = await this.listAudioInputDevices();
    const requestedDevice = session.capture.audioDevice;
    const resolvedDevice = requestedDevice
      ? availableDevices.find((device) => device.index === requestedDevice.index)
      : selectDefaultAudioDevice(availableDevices);

    if (!resolvedDevice) {
      throw new Error("No AVFoundation audio input devices were found.");
    }

    session.capture.recorder = "ffmpeg-avfoundation";
    session.capture.audioDevice = resolvedDevice;

    await mkdir(path.dirname(targetPath), { recursive: true });

    const args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-f",
      "avfoundation",
      "-i",
      `:${resolvedDevice.index}`,
      "-vn",
      "-ac",
      "1",
      "-ar",
      "16000",
      "-c:a",
      "aac",
      "-movflags",
      "+faststart",
      targetPath,
    ];

    const child = spawn("ffmpeg", args, {
      stdio: ["pipe", "ignore", "pipe"],
    });

    const startedAt = new Date().toISOString();
    const stderr: string[] = [];
    const activeRecording: ActiveRecording = {
      child,
      startedAt,
      stderr,
      exitCode: null,
      exitSignal: null,
      exitPromise: Promise.resolve(),
    };

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => {
      stderr.push(chunk.trim());
    });

    activeRecording.exitPromise = new Promise<void>((resolve, reject) => {
      child.once("error", reject);
      child.once("exit", (code, signal) => {
        activeRecording.exitCode = code;
        activeRecording.exitSignal = signal;
        resolve();
      });
    });

    this.activeRecordings.set(session.id, activeRecording);

    await sleep(450);

    const active = this.activeRecordings.get(session.id);

    if (!active) {
      throw new Error(`Recording startup state vanished for session ${session.id}.`);
    }

    if (active.exitCode !== null || active.exitSignal !== null) {
      this.activeRecordings.delete(session.id);
      throw new Error(
        `ffmpeg exited during recorder startup. ${
          stderr.filter(Boolean).join(" ") || "No stderr output."
        }`,
      );
    }
  }

  async stop(session: MeetingSession): Promise<AudioArtifact> {
    const active = this.activeRecordings.get(session.id);

    if (!active) {
      throw new Error(`No active recorder was found for session ${session.id}.`);
    }

    const targetPath = session.paths.audioFile;

    if (!targetPath) {
      throw new Error("Audio file path is not configured for this session.");
    }

    if (!active.child.stdin) {
      throw new Error("ffmpeg recorder stdin is unavailable, cannot stop recording cleanly.");
    }

    active.child.stdin.write("q\n");
    active.child.stdin.end();

    await active.exitPromise;
    this.activeRecordings.delete(session.id);

    if (active.exitCode !== 0 && active.exitCode !== null) {
      throw new Error(
        `ffmpeg failed while finalizing the recording. ${
          active.stderr.filter(Boolean).join(" ") || `Exit code ${active.exitCode}.`
        }`,
      );
    }

    const audioStat = await stat(targetPath);

    if (audioStat.size === 0) {
      throw new Error("The recorder exited but produced an empty audio file.");
    }

    return {
      path: targetPath,
      startedAt: active.startedAt,
      endedAt: new Date().toISOString(),
    };
  }
}
