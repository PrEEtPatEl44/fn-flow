# Contributing to Fn-flow

Thanks for helping make local, private dictation better on the Mac! Bug reports, ideas,
docs, and code are all welcome.

- **New here?** Start with a [`good first issue`](https://github.com/PrEEtPatEl44/fn-flow/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22).
  Each has a clear scope and acceptance criteria.
- **Have a question or an idea?** Open a [Discussion](https://github.com/PrEEtPatEl44/fn-flow/discussions) first.
- **Found a bug?** Use the bug report template. On Home, expand a dictation to see the raw
  transcript next to what was pasted, which is the most useful thing to include.
- **Security issue?** Please report it privately: see [SECURITY.md](SECURITY.md).

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting set up

You need an **Apple Silicon Mac on macOS 14+** and **Xcode 26 or newer** (Swift 6.2+).

```bash
git clone https://github.com/PrEEtPatEl44/fn-flow.git
cd fn-flow
swift build && swift test          # unit tests, no models needed
scripts/build_app.sh --run         # build the signed app and launch it
```

On first launch, **Settings › Local engine** downloads the speech model (~450 MB). Ollama is
optional; without it, cleanup uses built-in rules.

Test the app through `scripts/build_app.sh`, not `swift run`: the Microphone and
Accessibility permissions need a real `.app` bundle. The script signs it with a stable local
identity, so macOS keeps the Accessibility permission across rebuilds.

## Where things live

| Area | Code |
|---|---|
| Hotkey, dictation flow | `Sources/Core/Hotkey/`, `Sources/Core/Flow/FlowController.swift` |
| Live audio, streaming | `Sources/Core/Audio/`, `Sources/Core/AI/StreamingDictation.swift` |
| Speech-to-text (Parakeet, in-process) | `Sources/Core/AI/SpeechEngine.swift`, `Sources/Core/Models/ModelManager.swift` |
| Cleanup (Nemotron + rules), lists | `Sources/Core/AI/AIBridge.swift`, `Sources/Core/AI/TextCleaner*.swift` |
| App window (Home, Insights, Word Book, Settings) | `Sources/UI/Window/`, design tokens in `Sources/UI/Theme/` |
| Overlay | `Sources/UI/Overlay/` |

[CLAUDE.md](CLAUDE.md) explains the architecture and the non-obvious decisions (for
example, why streaming only commits words with speech after them). Read the relevant part
before changing streaming or cleanup.

## Tests and the benchmark

```bash
swift test                                              # unit tests (CI runs these)
swift test --filter TextCleanerTests                    # one suite
FN_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests   # real audio, real model
```

If your change touches transcription or cleanup, run the latency and quality benchmark
before and after, and put the numbers in your PR:

```bash
FN_FLOW_BENCH=1 FN_FLOW_BENCH_LABEL=before swift test --filter BenchmarkTests
python3 bench/compare.py before-baseline before-optimized
```

It uses the public synthetic dataset in `bench/dataset.sample.json`. Never add real
personal dictations to it; use a git-ignored `bench/data/dataset.json` for your own.

## Pull requests

- Keep each PR to one concern, and each commit building on its own.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(streaming): …`, `fix(cleanup): …`, `docs: …`, `test(bench): …`, `chore: …`.
- Fill in the PR template: what changed, why, and how you tested it.
- CI runs `swift build` and `swift test` on every PR.

A few identifiers deliberately keep the app's original name ("Nemotron Flow"): the bundle ID
`dev.nemotronflow.app`, `~/Library/Application Support/NemotronFlow/`, and the signing
identity. Renaming them would reset people's permissions and settings, so please don't.
