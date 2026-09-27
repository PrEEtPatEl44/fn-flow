<div align="center">

# Fn-flow

**Free, open-source Wispr Flow alternative for macOS.**<br>
Hold a key, speak, let go: your words appear wherever you're typing, cleaned up and ready.<br>
**100% local and private** · **fast** (~0.05 s after you stop talking) · **Swift-native**

[![CI](https://github.com/PrEEtPatEl44/fn-flow/actions/workflows/ci.yml/badge.svg)](https://github.com/PrEEtPatEl44/fn-flow/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![Good first issues](https://img.shields.io/github/issues/PrEEtPatEl44/fn-flow/good%20first%20issue?label=good%20first%20issues&color=7057ff)](https://github.com/PrEEtPatEl44/fn-flow/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)

</div>

---

Fn-flow is a **voice-to-text dictation app for Mac** in the spirit of Wispr Flow, except
nothing leaves your machine. Speech is transcribed on your Mac with NVIDIA's **Parakeet** model
running on the **Apple Neural Engine**, then cleaned up locally: filler words removed,
self-corrections like "actually no" or "scratch that" applied, lists formatted. The result is
pasted at your cursor in any app: Slack, Mail, Notes, your editor, the browser.

No account. No subscription. No word limits. No cloud.

## Why Fn-flow

- **Private by design.** Audio and text are processed entirely on your Mac. There's no server,
  no telemetry, and no network access after the one-time model download.
- **Fast.** Fn-flow transcribes and cleans up *while you're still talking*, so the text is
  ready about **0.05 s after you let go**, whether you spoke for 3 seconds or a minute.
  [Measured, not claimed](#performance).
- **Swift-native.** Built with Swift and SwiftUI, not Electron: a 19 MB app that feels at home
  on macOS and runs speech recognition on the Neural Engine via Core ML.
- **Careful with your words.** A local LLM tidies the text, but a guard rejects any output that
  isn't built from what you actually said. It won't "answer" a question you dictated, summarize
  your notes, or quietly drop a sentence.
- **Free and open source** under the MIT license.

| | Wispr Flow | **Fn-flow** |
|---|---|---|
| Where speech is processed | Cloud | **On your Mac** |
| Price | Subscription (limited free tier) | **Free** |
| Source code | Closed | **Open (MIT)** |
| Account required | Yes | **No** |
| Works offline | No | **Yes** |

## Features

- **Hold-to-talk** from any app with a hotkey you choose (Right ⌥ by default, or Fn, or any
  combo), or click the floating pill for hands-free dictation.
- **Paste at the cursor** and/or **copy to the clipboard**.
- **Smart cleanup:** removes "um" and "uh", applies spoken corrections, formats spoken lists as
  bullets, and adds missed question marks.
- **Personal dictionary** that learns from your fixes: correct a misheard name once, and it's
  spelled right next time.
- **History** of every dictation: what the model heard next to what was pasted, with timings.
- **A small, calm overlay** with a live waveform, on the edge of the screen you choose.

## Install

Fn-flow is young: a signed download and a Homebrew cask are on the way
([help wanted](https://github.com/PrEEtPatEl44/fn-flow/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22)).
For now, build it from source. You need an **Apple Silicon Mac** on **macOS 14 or newer** and
Xcode.

```bash
git clone https://github.com/PrEEtPatEl44/fn-flow.git
cd fn-flow
scripts/build_app.sh --install   # builds, signs, copies to ~/Applications, and launches
```

On first launch:

1. **Settings › Local engine → Download** the speech model (NVIDIA Parakeet TDT 0.6B, ~450 MB, once).
2. *Optional:* install [Ollama](https://ollama.com/download), then download **NVIDIA Nemotron**
   in the same card for smarter cleanup. Without it, built-in rules still remove fillers and
   apply corrections.
3. **Settings › Mac access:** allow **Accessibility** (for the hotkey and pasting) and the
   **Microphone**.
4. Hold **Right ⌥**, speak, and let go. Press **Esc** to cancel.

## Performance

Latency is the wait after you stop speaking until the text is ready. It's measured by the
benchmark in this repo (`Tests/BenchmarkTests.swift`), which feeds real recorded dictations
through the full pipeline and grades every output against a hand-written ideal version.

| Dictation length | Before streaming | Now | Correctness |
|---|---|---|---|
| Short (under ~25 words) | 0.47 s | **0.05 s** | 95.9 |
| Medium (25–90 words) | 1.79 s | **0.17 s** | 88.1 |
| Long (90+ words, up to ~60 s of speech) | 4.91 s | **0.06 s** | 95.6 |

*MacBook Air (M5, 24 GB), 24 recorded dictations. Correctness is 100 × (1 − word error rate)
against the ideal output; formatting checks (fillers removed, lists, punctuation) pass at 100%.*

## How it works

```
hold the key → live audio (16 kHz) → overlay with waveform
while you talk → every few seconds: Parakeet on the Neural Engine → words with timings
                → words with enough speech after them are committed and cleaned up
let go         → only the last second or two is left: transcribe it, clean it up
               → personal dictionary → paste at the cursor / copy
```

- **Speech-to-text:** [NVIDIA Parakeet TDT 0.6B v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
  as Core ML models, via [FluidAudio](https://github.com/FluidInference/FluidAudio).
- **Cleanup:** [NVIDIA Nemotron Mini](https://huggingface.co/nvidia/Nemotron-Mini-4B-Instruct)
  through [Ollama](https://ollama.com) (optional), plus deterministic rules for fillers,
  corrections, lists, and punctuation.
- More detail on the architecture and design decisions is in [CLAUDE.md](CLAUDE.md).

## FAQ

**Is there a free, open-source alternative to Wispr Flow?**
Yes, that's what Fn-flow is: free, MIT-licensed, and fully local on macOS.

**Does it work offline?**
Yes. After the one-time model download, everything runs on your Mac with no internet
connection.

**Is my voice sent anywhere?**
No. Audio is processed in memory on your Mac. History is stored locally and can be cleared
in Settings.

**Which Macs are supported?**
Apple Silicon Macs (M1 or newer) on macOS 14 Sonoma or later.

**Do I need Ollama?**
No. It's optional and enables the smarter Nemotron cleanup. Without it, dictation still works
with built-in cleanup rules.

**Does it support languages other than English?**
Not yet: it uses the English Parakeet model. Multilingual support would be a great
contribution; Parakeet v3 covers 25 European languages.

## Contributing

Contributions of every size are welcome: code, bug reports, docs, ideas.

- Browse the [good first issues](https://github.com/PrEEtPatEl44/fn-flow/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
  and [help wanted](https://github.com/PrEEtPatEl44/fn-flow/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) issues.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests, and the benchmark.
- Share ideas and questions in [Discussions](https://github.com/PrEEtPatEl44/fn-flow/discussions).

If Fn-flow is useful to you, a ⭐ helps other people find it.

## Acknowledgments

- [FluidAudio](https://github.com/FluidInference/FluidAudio) for Core ML speech recognition
  on Apple Silicon.
- NVIDIA for the open [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) and
  [Nemotron](https://huggingface.co/nvidia/Nemotron-Mini-4B-Instruct) models.
- [Handy](https://github.com/cjpais/Handy), whose in-app model setup inspired ours.
- [Ollama](https://ollama.com) for local LLM serving.

## License

[MIT](LICENSE) © 2026 Preet Patel
