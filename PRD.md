# PRD: Fn-flow (Wispr Clone)

## 1. Project Overview
Fn-flow is a native macOS application that provides a seamless "voice-to-text anywhere" experience. It mimics the "hold-to-talk" and "release-to-paste" workflow of Wispr Flow, leveraging local AI (Nemotron/Parakeet) for privacy and speed.

## 2. Core Value Proposition
High-fidelity, context-aware dictation that removes filler words, handles self-corrections (backtracking), and integrates fluidly into any macOS text field with high-end animations.

## 3. Target Features (Must-Have)

### A. Input & Interaction
- **Hold-to-Talk Workflow**: Global hotkey to activate the microphone. Audio is captured while held and processed/pasted upon release.
- **Global Injection**: Ability to paste processed text into any active application (Accessibility API / AppleScript).

### B. Local AI Engine (The "Brain")
- **Transcription**: Use **Nvidia Parakeet** (via local inference) for high-accuracy speech-to-text.
- **Processing**: Use **Nemotron** for:
    - **Filler Word Removal**: Stripping "um", "uh", and repetitive stutters.
    - **Smart Formatting**: Automatic punctuation, capitalization, and list creation.
    - **Backtrack/Self-Correction**: Recognizing phrases like "actually," "scratch that," or "never mind" to rewrite the preceding segment of the dictation.
- **Personal Dictionary**: A local database of custom terms and names that the model learns from manual corrections.

### C. The "Flow" Experience (Animations & UI)
- **Glow Ring / Visual Feedback**: A high-frame-rate animated glow or "pill" that follows the cursor or appears centered on screen during recording.
- **Smooth Transitions**: Use SwiftUI/Metal for fluid, physics-based animations (springs, blurring) similar to the "Flow Bar".
- **Non-Intrusive Notifications**: Subtle "mini-toasts" to indicate when smart formatting or backtracking has occurred.

### D. Manual Correction Sync
- **Dynamic Update**: If the user manually edits a word in the text box after the AI has pasted it, the system should treat this as a "gold label" correction and update the local dictionary/context to improve future transcriptions of that specific term.

## 4. Technical Stack
- **Language**: Swift 6.0+
- **UI Framework**: SwiftUI (for the app and overlays)
- **Local AI Runtime**: 
    - Local LLM/ASR hosting (e.g., via NVIDIA NIM local or a custom C++/Python wrapper accessible via XPC/Localhost).
    - Model: Nemotron (Text processing) + Parakeet (ASR).
- **OS Integration**: macOS Accessibility Framework, Core Audio, and AppleScript/AXUIElement for text injection.

## 5. Resources & References
- **Wispr Flow Docs**: https://docs.wisprflow.ai/
- **NVIDIA Parakeet**: High-performance ASR models.
- **NVIDIA Nemotron**: Optimized LLMs for text refinement.
- **Apple Human Interface Guidelines (HIG)**: For fluid motion and macOS system integration.
