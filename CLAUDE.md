# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Fn-flow**, a macOS menu bar app (Swift 6, SwiftUI, macOS 14+, Apple Silicon): hold a hotkey,
speak, release, and the text is pasted at the text cursor. Transcription and cleanup run fully
locally. Product spec: `PRD.md`.

The app was originally called "Nemotron Flow". A few identifiers deliberately keep that name,
because changing them would reset users' permissions, settings, or installed models:
- the bundle ID and log subsystem `dev.nemotronflow.app`
- `~/Library/Application Support/NemotronFlow/`
- the "Nemotron Flow Local Signing" identity

Don't rename these. "Nemotron" elsewhere means the NVIDIA model, not the app.

## Commands

```bash
swift build                                   # debug build
swift test                                    # unit tests (Swift Testing)
swift test --filter TextCleanerTests          # one suite
swift test --filter "CorrectionDiffTests/learnsMisheardName"  # one test
FN_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests  # e2e; downloads the speech model on first run
FN_FLOW_BENCH=1 FN_FLOW_BENCH_LABEL=x swift test --filter BenchmarkTests  # latency + quality benchmark
python3 bench/compare.py x-baseline x-optimized                           # compare its two variants
scripts/build_app.sh [--run|--install]        # signed .app in build/ (required for real use)
/usr/bin/log stream --predicate 'subsystem == "dev.nemotronflow.app"'   # app logs
```

- Use the full `/usr/bin/log` path: zsh's `log` builtin shadows it and silently returns nothing.
- `swift run` is not a usable way to test the app. Microphone and Accessibility permissions need the
  bundle's `Info.plist` and signature, so always test through `scripts/build_app.sh`.
- There is no linter configured.
- The benchmark reads `bench/data/dataset.json` if it exists, otherwise the committed
  `bench/dataset.sample.json` (synthetic cases only). Each case has a gold output. It writes
  `bench/results/`. `bench/data/` and `bench/results/` are **git-ignored and local-only**,
  because the private dataset is built from personal dictations. Never commit personal
  dictations to the sample. It runs a `baseline` (original, whole-file) and an `optimized` (streaming)
  variant interleaved on every case, because this MacBook Air throttles, so runs minutes apart
  aren't comparable. Knobs: `FN_FLOW_BENCH_RUNS`, `FN_FLOW_BENCH_SPEED` (feed audio faster than
  real time), `FN_FLOW_BENCH_ONLY=id1,id2`.

## Architecture

The flow is two processes, plus Ollama:

```
HotkeyManager (CGEvent tap) → FlowController → RecordingManager (AVAudioEngine, live 16 kHz)
  → StreamingDictation, while the user speaks:
      every few seconds: SpeechEngine (in-process Parakeet v2, Core ML on the Neural Engine
      via FluidAudio, with word timings) → commit stable words → AIBridge.cleanChunk
      (Ollama /api/chat, nemotron-mini, or rules)
  → at release: transcribe + clean only the leftover → AIBridge.finalize (format, dictionary)
  → AccessibilityManager.deliver (⌘V and/or clipboard) → CorrectionTracker (learns edits)
```

- **Streaming is the latency fix (#7).** Waiting until release made the wait grow with
  dictation length (median ~7 s for 50 s of speech). `StreamingDictation` does nearly all the
  work while the user speaks, leaving ~0.2 s after release:
  - It **commits only words with ≥1 s of speech after them** in the window. A word at the
    window's edge is transcribed without its context, so Parakeet may mis-punctuate it (full
    stops and capitals mid-sentence). Uncommitted audio is re-transcribed with the next
    window. Keep this rule if you change the windowing.
  - Cleanup is **speculative**: a chunk starting with a correction ("Scratch that, …")
    re-cleans the previous chunk together with it.
  - Speech-to-text and cleanup each have **one worker**. Pending cuts coalesce into the
    latest end point, so a backlog becomes one bigger window rather than a queue. After
    release, cleanup gets a 1.5 s budget, then Nemotron is cancelled and the rules finish.
    `cancel()` cancels in-flight requests too. Backends are injectable, and
    `StreamingTests` uses fakes.
  - `RecordingManager` hands audio over through a locked `SampleBuffer`, and `stop()` drains
    it after stopping the engine, so the last batch always lands in the stream and the WAV.
- **Parakeet occasionally emits a run of `<unk>` tokens** (a degenerate decode, seen with the
  earlier MLX runtime; the same audio transcribed fine moments later). It hasn't been
  reproduced on demand. `SpeechEngine` retries once, strips what's left, and reports
  `unknownTokens`; streaming won't commit such a window. The offending audio is kept in
  `~/Library/Application Support/NemotronFlow/diagnostics/` (newest 10): use it to find the
  root cause.
- **`SpeechEngine` pads audio with 0.5 s of silence.** Without it, Parakeet can invent words
  when speech is cut off abruptly ("…instead of just" → "…adjusting the majority").
  - `AIBridge.process(audioURL:)` is the whole-file path (Undo, and the fallback if
    streaming fails). Both paths share `cleanChunk` and `finalize`.
- **Nemotron generation (~35–45 tokens/s on this M5 Air) is the hard limit**, and Ollama
  serves one request at a time, so concurrent requests don't help. MLX was tested: no faster,
  and it reworded more. So: skip Nemotron for chunks the rules fully handle
  (`TextCleaner.needsLLM`), cap its output length, and keep the model loaded (24 h).

- **`FlowController`** is the state machine (idle → listening → processing) and the only place
  that wires the managers together. Most other types are `@MainActor` singletons (`.shared`).
- **`ModelManager`** owns the models, all managed inside the app (#6; modeled on how Handy
  provides models). No bash, Python, or Homebrew:
  - Speech: Parakeet v2 Core ML (~450 MB) downloaded from Hugging Face by FluidAudio into
    `…/NemotronFlow/models/parakeet-tdt-0.6b-v2`, with live progress, then loaded by
    `SpeechEngine`. FluidAudio treats the given folder's *parent* as the models directory
    and uses its own folder name, so keep `speechModelDirectory` matching that name. An
    existing FluidAudio cache is reused.
  - Cleanup: Nemotron through Ollama is **optional** and never installed by the app; if Ollama
    is present, the model is pulled through its API (`/api/pull`, streamed progress).
    Without it, dictation uses the rule-based cleanup.
  - The pre-#6 Python runtime folder (`…/NemotronFlow/runtime/`, ~5 GB) is no longer used and
    never deleted automatically; Settings › Local engine offers to remove it.
- **The LLM is a cleanup stage, not an assistant, and its output is untrusted.** Left
  unconstrained, `nemotron-mini` answers, summarizes or outlines dictated instructions ("we
  need to add…"). Three layers stop that:
  - The system prompt states its narrow job.
  - Text goes in ~45-word chunks (`TextCleaner.chunks`; run-on sentences are split by
    `cleanupUnits`, and `joinCleaned` repairs mid-sentence joins), because the small model
    rewrites long inputs.
  - `TextCleaner.isFaithful` rejects any chunk that adds words, drops content words, or
    opens with a reply ("Sure, here's…"). A rejected chunk falls back to `TextCleaner.clean`.
  Formatting (bullets, question marks) is deliberately **not** in the prompt:
  `TextCleaner.format` does it deterministically afterwards. Keep few-shot example topics
  unrelated to real dictation, or the model copies them into the output.
- **Correction learning** (`CorrectionTracker` / `CorrectionDiff`): after a paste, it polls the
  focused `AXUIElement`'s value and learns word substitutions only if they "sound alike"
  (phonetic key + edit distance). This keeps content edits like Tuesday → Wednesday out of the
  dictionary. The dictionary is stored in `…/NemotronFlow/dictionary.json`.
- **Overlay**: a click-through, non-activating `NSPanel` (`hidesOnDeactivate = false`) that eases
  toward the mouse on a 60 Hz timer. `OverlayModel.phase` drives all SwiftUI states and
  transitions.

## Gotchas

- **Never do work inside the CGEvent tap callback.** macOS disables taps that block (starting the
  mic can take ~1s), and the key-release event is then lost. `HotkeyManager.fire` defers
  callbacks to the next main-queue turn.
- **Hotkey model**: modifier-only hotkeys match on `.flagsChanged` using device-specific flag bits
  (to tell left from right); combos match on keyDown/keyUp and are swallowed. Plain letters
  without modifiers are rejected (`Hotkey.isAcceptable`).
- **Accessibility is tied to the code signature.** `build_app.sh` signs with an Apple identity if
  one exists, otherwise a self-signed "Nemotron Flow Local Signing" identity stored in
  `…/NemotronFlow/signing/signing.keychain-db`. Don't switch to ad-hoc signing: every rebuild
  would then silently void the grant. To reset: `tccutil reset Accessibility dev.nemotronflow.app`.
- **Swift 6 strict concurrency** (`ApproachableConcurrency`): C callbacks and `Timer` closures use
  `MainActor.assumeIsolated`. Use string literals like `"AXFocusedUIElement" as CFString` instead
  of the imported `kAX…` globals.
