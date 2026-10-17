# Dataset Fixtures

This directory stores small, repeatable audio subsets for regression checks.

## Manifest Format

Use `manifest.jsonl` with one JSON object per line:

```json
{"id":"sample-001","source":"magicdata-dev","audioFile":"magicdata_dev_subset/sample-001.wav","expectedTranscript":"今天天气很好"}
```

Fields:

- `id`: stable sample id
- `source`: dataset/source label
- `audioFile`: relative path from the manifest file to the audio clip
- `expectedTranscript`: reference transcript used for character-error checks
- `note`: optional context

## Legacy Post-Processing Evaluation

Run:

```bash
npm run eval-dataset -- --manifest fixtures/datasets/manifest.jsonl
```

Results are written to:

`runtime/evaluations/`

This legacy script evaluates the TypeScript post-processing harness, not live speech-to-text provider accuracy.

## Recommended Meeting Benchmark

Use AISHELL-4 as the primary public benchmark for Chinese meeting transcription. It is much closer to WalleBrain's target use case than the existing MagicData short-command subset.

Dataset:

- AISHELL-4 on OpenSLR: https://openslr.org/111/
- Recommended first pass: download and extract the AISHELL-4 test set under `runtime/datasets/aishell4/test`.
- The test archive is several GB, so it is intentionally not downloaded by repo scripts.

Prepare a small meeting-slice manifest:

```bash
npm run prepare-aishell4-subset -- \
  --source-dir runtime/datasets/aishell4/test \
  --limit 20 \
  --min-duration 60 \
  --max-duration 180
```

This writes:

- `fixtures/datasets/aishell4_meeting_subset/*.wav`
- `fixtures/datasets/aishell4_manifest.jsonl`

Then run the provider benchmark:

```bash
./scripts/build_native_bundle.sh WalleBrainTranscriptionBenchmark WalleBrainTranscriptionBenchmark com.wallebrain.transcription-benchmark
runtime/native/WalleBrainTranscriptionBenchmark.app/Contents/MacOS/WalleBrainTranscriptionBenchmark \
  --provider both \
  --language zh \
  --manifest fixtures/datasets/aishell4_manifest.jsonl \
  --sample-timeout 300 \
  --realtime-final-drain 8
```

For meeting-length clips, prefer CER and per-sample transcripts over exact-match rate. Exact match is too strict for long speech.

## Legacy Short-Command Benchmark

The existing `fixtures/datasets/manifest.jsonl` MagicData subset is useful only as a fast smoke/regression check for short Mandarin commands. Do not use it to judge meeting transcription quality.

## Native Transcription Benchmark Tool

Use the Swift benchmark when comparing Apple Speech and OpenAI Realtime transcription accuracy on the same labeled audio:

```bash
swift run WalleBrainTranscriptionBenchmark --provider both --language zh --manifest fixtures/datasets/manifest.jsonl
```

Provider-specific runs:

```bash
swift run WalleBrainTranscriptionBenchmark --provider apple-speech --language zh
swift run WalleBrainTranscriptionBenchmark --provider openai-realtime --language zh
```

Results are written to `runtime/evaluations/` as both JSON and Markdown. The summary includes average Chinese character error rate (CER), character accuracy, exact-match rate, and per-sample transcripts/errors.

Notes:

- `openai-realtime` requires `OPENAI_API_KEY`.
- `apple-speech` requires macOS Speech recognition permission. If macOS rejects the raw CLI because it lacks app-bundle usage metadata, build a bundle:

```bash
./scripts/build_native_bundle.sh WalleBrainTranscriptionBenchmark WalleBrainTranscriptionBenchmark com.wallebrain.transcription-benchmark
runtime/native/WalleBrainTranscriptionBenchmark.app/Contents/MacOS/WalleBrainTranscriptionBenchmark --provider apple-speech --language zh
```

## Current Plan

- Use AISHELL-4 meeting slices for product-relevant Chinese meeting evaluation.
- Keep MagicData short-command samples only for fast local smoke checks.
- Add a small private golden set from real WalleBrain meetings when manually corrected transcripts are available.
