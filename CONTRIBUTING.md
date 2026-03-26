# Contributing

Thanks for contributing to WalleBrain.

## Before You Open a PR

Please make sure these commands pass locally:

```bash
swift test
```

If you touch the legacy TypeScript harness, also run:

```bash
npm run typecheck
```

## Scope

The primary product path is the native macOS app under:
- `Sources/WalleBrainApp`
- `Sources/WalleBrainCore`

The `src/` and Vite-based code is legacy prototype code. Changes there are still welcome, but please keep it clear whether a PR affects:
- native app
- legacy harness
- both

## Do Not Commit

- API keys or real secrets
- local runtime artifacts under `runtime/`
- local planning notes
- machine-specific configuration

## Notes

- System audio capture depends on macOS permissions and can behave differently across machines.
- The repository is not yet set up for notarized public macOS releases.
