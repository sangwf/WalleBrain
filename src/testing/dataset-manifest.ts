import { readFile } from "node:fs/promises";
import path from "node:path";

export type DatasetSample = {
  id: string;
  source: string;
  audioFile: string;
  expectedTranscript: string;
  note?: string;
};

export type DatasetEvaluationResult = {
  id: string;
  source: string;
  audioFile: string;
  expectedTranscript: string;
  actualTranscript: string;
  charErrorRate: number;
  isExactMatch: boolean;
  summary: string;
  model: string | null;
  provider: string;
};

export function normalizeTextForComparison(input: string): string {
  return input
    .normalize("NFKC")
    .replace(/\s+/g, "")
    .replace(/[，。、“”‘’！!？?；;：:,.-]/g, "")
    .trim()
    .toLowerCase();
}

function levenshteinDistance(left: string, right: string): number {
  if (left === right) {
    return 0;
  }

  if (left.length === 0) {
    return right.length;
  }

  if (right.length === 0) {
    return left.length;
  }

  const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  const current = new Array<number>(right.length + 1).fill(0);

  for (let row = 1; row <= left.length; row += 1) {
    current[0] = row;

    for (let column = 1; column <= right.length; column += 1) {
      const substitutionCost = left[row - 1] === right[column - 1] ? 0 : 1;
      current[column] = Math.min(
        current[column - 1] + 1,
        previous[column] + 1,
        previous[column - 1] + substitutionCost,
      );
    }

    for (let column = 0; column <= right.length; column += 1) {
      previous[column] = current[column];
    }
  }

  return previous[right.length];
}

export function computeCharacterErrorRate(expected: string, actual: string): number {
  const normalizedExpected = normalizeTextForComparison(expected);
  const normalizedActual = normalizeTextForComparison(actual);

  if (!normalizedExpected) {
    return normalizedActual ? 1 : 0;
  }

  return Math.min(
    1,
    levenshteinDistance(normalizedExpected, normalizedActual) / normalizedExpected.length,
  );
}

export function isNormalizedExactMatch(expected: string, actual: string): boolean {
  return normalizeTextForComparison(expected) === normalizeTextForComparison(actual);
}

export async function loadDatasetManifest(manifestPath: string): Promise<DatasetSample[]> {
  const raw = await readFile(manifestPath, "utf8");

  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => JSON.parse(line) as DatasetSample)
    .map((sample) => ({
      ...sample,
      audioFile: path.resolve(path.dirname(manifestPath), sample.audioFile),
    }));
}
