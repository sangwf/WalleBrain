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

## Evaluation

Run:

```bash
npm run eval-dataset -- --manifest fixtures/datasets/manifest.jsonl
```

Results are written to:

`runtime/evaluations/`

## Current Plan

- Use a small official Chinese subset rather than a full corpus for every run.
- Start with MAGICDATA `dev_set` samples.
- Keep the fixture set small enough for fast local acceptance checks.
