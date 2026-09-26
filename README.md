# Fn-flow

Hold a hotkey, speak, release: your words are transcribed and cleaned up locally,
then pasted wherever your text cursor is. See [PRD.md](PRD.md).

## Quick start

```bash
scripts/build_app.sh --install   # builds, signs, copies to ~/Applications, launches
```

On first launch:

1. **Models** tab → **Download** the speech model (NVIDIA **Parakeet TDT 0.6B**, ~450 MB,
   one time). It runs inside the app on Apple's Neural Engine; nothing else to install.
2. Optional: install [Ollama](https://ollama.com/download), then **Download** NVIDIA
   **Nemotron** in the same tab for smarter cleanup. Without it, built-in rules still remove
   fillers and apply corrections.
3. **Permissions** tab → grant **Accessibility** (hotkey + paste) and **Microphone**.
4. Hold **Right ⌥** (default), speak, release. Press **Esc** while holding to cancel.

## Pipeline

```
hotkey down → record live 16 kHz audio → overlay
while speaking → every few seconds: Parakeet (in-process, Neural Engine) → Nemotron (Ollama)
hotkey up   → finish only the last few seconds → personal dictionary
            → paste at the cursor and/or copy → watch for manual corrections
```

- **Streaming:** transcription and cleanup happen *while you speak*, so the text is ready
  about 0.05 s after release, however long you talk. (Before streaming, a 50-second
  dictation took about 7 s.)
- **Nemotron cleanup** removes fillers, applies self-corrections ("actually no",
  "scratch that"), and fixes punctuation and lists. If the LLM's output isn't built from
  the words you said (e.g. it tries to *answer* a question), it's discarded in favor of
  the rule-based `TextCleaner`.
- **Personal dictionary** (Settings → Dictionary): terms steer the prompt; replacements
  are applied to every dictation. If you fix a misheard word right after pasting
  ("cooper netties" → "Kubernetes"), the fix is learned automatically.

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
FN_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests  # downloads the speech model on first run
```

**Benchmark.** A latency and quality benchmark runs the original and the streaming pipeline
side by side. It grades correctness (word error rate against a hand-written ideal output)
and formatting.

```bash
FN_FLOW_BENCH=1 FN_FLOW_BENCH_LABEL=run swift test --filter BenchmarkTests
python3 bench/compare.py run-baseline run-optimized
```

It uses `bench/dataset.sample.json`, 9 synthetic dictations (short and long). To benchmark
your own dictations, put them in `bench/data/dataset.json`, which is used instead when it
exists and is git-ignored so personal text never gets committed. `FN_FLOW_BENCH_DATASET=path`
picks a dataset explicitly. Each case has an `id`, `category` (`small`/`medium`/`large`),
`speech` (spoken with `say` to make the audio), `gold` (the ideal output), and optional
`expect` checks. See `Tests/BenchmarkTests.swift`.

Without an Apple Development signing identity, builds are signed ad-hoc and macOS
forgets the Accessibility grant on every rebuild. Remove the app from System Settings ›
Privacy & Security › Accessibility and add it again.
