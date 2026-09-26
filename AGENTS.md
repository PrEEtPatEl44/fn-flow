# Agent guidance for Fn-flow

Fn-flow is a macOS 14+ menu bar app built with Swift 6 and SwiftUI. Hold a hotkey, speak, and release to transcribe, clean, and paste text locally. Read `PRD.md` for product behavior and `CLAUDE.md` for detailed architecture and platform gotchas.

## Work in this repository

- Complete clear, reversible tasks without asking for confirmation. Keep changes focused and verify them before reporting completion.
- Use `swift build` and `swift test` for normal code changes. Run focused tests first when a change has a specific test suite. There is no configured linter.
- Use `scripts/build_app.sh` to test the real app. `swift run` lacks the signed app bundle needed for Microphone and Accessibility permissions.
- Run integration tests with `FN_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests` only when the local runtime is available.
- Do not install models or reset macOS permissions as part of routine verification.

## Architecture and invariants

- `FlowController` owns the idle → listening → processing state machine. `HotkeyManager` captures input, `RecordingManager` records audio, `AIBridge` calls the local transcription and cleanup services, and `AccessibilityManager` delivers text.
- Keep the cleanup model constrained to faithful edits of dictated text. `TextCleaner.isFaithful` guards model output, and deterministic formatting runs afterward.
- Keep `runtime/server.py`'s `/transcribe` endpoint asynchronous. MLX streams are thread-local, and a synchronous FastAPI endpoint runs in a threadpool.
- Keep work out of the CGEvent tap callback; blocking it can cause macOS to disable the tap and lose key-release events.
- Preserve the legacy bundle ID and log subsystem `dev.nemotronflow.app`, the `~/Library/Application Support/NemotronFlow/` path, and the local signing identity. Changing them can reset user permissions, settings, or installed models.
- Accessibility permission depends on the app's code signature. Use the existing signing flow in `scripts/build_app.sh`.

## Useful paths

- `Sources/Core/Flow/FlowController.swift`: dictation lifecycle.
- `Sources/Core/AI/`: cleanup bridge and text safeguards.
- `Sources/Core/Hotkey/`: hotkey capture and validation.
- `Sources/UI/Overlay/`: overlay window and placement.
- `runtime/`: local ASR server and installer.
- `Tests/FnFlowTests.swift`: Swift Testing suites.
