# Nemotron Flow

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
hotkey down → record 16 kHz WAV → overlay follows cursor
hotkey up   → Parakeet (local server, :8765) → Nemotron (Ollama) → personal dictionary
            → ⌘V into the focused app (or clipboard only) → watch for manual corrections
```

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
| Output | Paste at cursor (optionally restore the clipboard afterwards) · clipboard only |
| Overlay | Follow mouse cursor · bottom center |
| Cleanup | Toggle Nemotron, choose the Ollama model |

## Development

```bash
swift build && swift test
NEMOTRON_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests  # needs the runtime running
```

Without an Apple Development signing identity, builds are signed ad-hoc and macOS
forgets the Accessibility grant on every rebuild. Remove the app from System Settings ›
Privacy & Security › Accessibility and add it again.
