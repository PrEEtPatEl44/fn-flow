# Fn-flow

Hold a hotkey, speak, release: your words are transcribed and cleaned up locally,
then pasted wherever your text cursor is. See [PRD.md](PRD.md).

## Quick start

```bash
scripts/build_app.sh --install   # builds, signs, copies to ~/Applications, launches
```

On first launch:

1. **Models** tab → **Install Models** (≈5 GB, one time). This runs
   `runtime/install_runtime.sh` and sets up the following in
   `~/Library/Application Support/NemotronFlow/runtime`:
   - uv + Python 3.12 venv with `parakeet-mlx` → NVIDIA **Parakeet TDT 0.6B** ASR
   - Ollama `nemotron-mini` → NVIDIA **Nemotron** cleanup
2. **Permissions** tab → grant **Accessibility** (hotkey + paste) and **Microphone**.
3. Hold **Right ⌥** (default), speak, release. Press **Esc** while holding to cancel.

## Pipeline

```
hotkey down → record live 16 kHz audio → overlay
while speaking → every few seconds: Parakeet (local server, :8765) → Nemotron (Ollama)
hotkey up   → finish only the last few seconds → personal dictionary
            → paste at the cursor and/or copy → watch for manual corrections
```

- **Streaming:** transcription and cleanup happen *while you speak*, so the wait after
  release stays about 0.2 s no matter how long you talk. Before this, a 50-second dictation
  took about 7 s.

- **Nemotron cleanup** removes fillers, applies self-corrections ("actually no",
  "scratch that"), and fixes punctuation and lists. If the LLM's output isn't built from
  the words you said (e.g. it tries to *answer* a question), it's discarded in favor of
  the rule-based `TextCleaner`.
- **Personal dictionary** (Settings → Dictionary): terms steer the prompt; replacements
  are applied to every dictation. If you fix a misheard word right after pasting
  ("cooper netties" → "Kubernetes"), the fix is learned automatically.
- The app launches and stops the ASR server itself; its log is `runtime/server.log`.

## Settings

| Setting | Options |
| --- | --- |
| Hotkey | Any lone modifier (Right ⌥/⌘/⌃/⇧, Fn), an F-key, or a modifier combo |
| After dictation | Paste at the cursor and/or copy to the clipboard (at least one on; paste-only restores your previous clipboard) |
| Overlay | Bottom, left, or right edge center (upright pill on the sides), with a draggable resting pill that snaps to the nearest edge · or follow the mouse cursor |
| Cleanup | Toggle Nemotron, choose the Ollama model |

## Development

```bash
swift build && swift test
FN_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests  # needs the runtime running
```

**Benchmark.** A latency and quality benchmark runs the original and the streaming pipeline
side by side. It grades correctness (word error rate against a hand-written ideal output)
and formatting.

```bash
FN_FLOW_BENCH=1 FN_FLOW_BENCH_LABEL=run swift test --filter BenchmarkTests
python3 bench/compare.py run-baseline run-optimized
```

It reads a dataset from `bench/data/dataset.json`, which is git-ignored because it's built
from personal dictations. Each case has an `id`, `category` (`small`/`medium`/`large`),
`speech` (spoken with `say` to make the audio), `gold` (the ideal output), and optional
`expect` checks. See `Tests/BenchmarkTests.swift`.

Without an Apple Development signing identity, builds are signed ad-hoc and macOS
forgets the Accessibility grant on every rebuild. Remove the app from System Settings ›
Privacy & Security › Accessibility and add it again.
