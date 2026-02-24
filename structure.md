# VALIS Project Structure

This document provides a detailed overview of the VALIS repository structure as it exists in the current codebase.

## Root Directory

- `ZephyrAI/`: Main iOS app target (SwiftUI).
- `Frameworks/`: Local binary frameworks.
  - `llama.xcframework`: Prebuilt llama.cpp framework.
- `ZephyrAI.xcodeproj`: Xcode project.
- `ZephyrAITests/`, `ZephyrAIUITests/`: Test targets.
- `AnyLanguageModel/`: Vendored upstream (provider-agnostic LLM examples; not wired into the app target).
- `mlx-swift/`: Vendored upstream MLX Swift repository (reference/experimentation; not wired into the app target).
- `swift-llama-cpp/`: Vendored Swift bindings / headers for llama.cpp (reference).
- `README.md`: Project overview.
- `structure.md`: This file.

## App Source (`ZephyrAI/`)

### Entry
- `ZephyrAI/ZephyrAIApp.swift`: SwiftUI app entry.
- `ZephyrAI/ContentView.swift`: Root view.

### Views (`ZephyrAI/Views/`)
- `ChatView.swift`: Main chat UI.
  - Presents Settings as a translucent sheet (`presentationBackground(.clear)`), leaving the chat visible underneath.
  - Message list + input + microphone recording flow.
- `SettingsView.swift`: Persona prompt editor + navigation to Memories.
  - Uses a glass distortion backdrop (SwiftUI `distortionEffect`) with tunable opacity.
  - Toolbar uses SF Symbols (xmark / checkmark) and adapts to light/dark.
  - On visionOS 26+, optionally applies `presentationBreakthroughEffect`.
- `MemoryListView.swift`: Memory management UI.
  - Pin/unpin/delete/edit, clear confirmations, multi-select pin.
  - Uses a glass distortion backdrop like Settings.
  - Shader animation is gated to the view lifetime to reduce battery drain.

### ViewModels (`ZephyrAI/ViewModels/`)
- `ChatViewModel.swift`: Orchestration layer.
  - Builds the system prompt from multiple context blocks:
    - `IdentityService` prompt
    - `IdentityProfileService` context block
    - `EmotionService` internal affect block (self-access)
    - tool context (Date / DuckDuckGo / Reddit news)
    - `ExperienceService` lessons + preferences
    - `MotivationService` guidance
    - response detail level
    - optional “spontaneous flavor” (small randomized tone variation; gated for serious prompts)
  - Streams generation and parses `<think>...</think>` using `ThinkStreamParser`.
  - Tooling:
    - Rule-based tools: inject Date/Web/News context based on user intent triggers.
    - Model-initiated tools: parses `TOOL:` lines and re-runs generation with tool results.
    - Multi-step tool loop: bounded tool-call/rerun iterations with cycle detection.
    - Tool parser is tolerant to variants (e.g. `TOOL: news` -> `reddit_news`).
  - Autonomous memory:
    - listens to `.memoryTriggered` and can perform a spontaneous “learn” response when idle.
  - Speech:
    - speech-to-text transcription pipeline (SFSpeechRecognizer).

### Models (`ZephyrAI/Models/`)
- `Message.swift`: Chat message model.

### Services (`ZephyrAI/Services/`)
- `LLMService.swift`: High-level LLM interface.
  - Loads GGUF model from bundle/Documents.
  - Streams output and supports cancellation.
  - Uses `MemoryService.getContextBlock(maxChars:)` to inject memory context.
  - Applies a “cognitive relevance” heuristic to store one strong sentence back into memory.
- `LlamaRuntime.swift`: llama.cpp runtime wrapper.
  - Clamps `n_ctx` to the model’s `n_ctx_train`.
  - Uses smaller `n_batch` and split-on-error decode for `Decode failed with code 1` resilience.
  - Rebuilds context per request to keep the KV cache clean.
- `MemoryService.swift`: Plastic Brain.
  - Stores and persists `Memory` objects (emotion, importance, embeddings, links, prediction signals).
  - Maintains `MemoryGraph` + `CognitiveEchoGraph`.
  - Echo/spontaneous loops, activation/decay, pruning.
  - Produces the bounded memory context block injected into the system prompt.
- `EmotionService.swift`: Internal affect state.
  - Maintains a slow-changing (valence/intensity/stability) state with decay.
  - Provides a self-access context block; intended to be mentioned sparingly.
- `AutonomousMemorySources.swift`: Optional external snippet fetchers.
  - `DuckDuckGoSource`, `WikipediaSource`.
- `IdentityService.swift`: Persona prompt storage.
  - Auto-migrates stored prompts to include tool-request instructions.
- `IdentityProfileService.swift`: Versioned “living identity” profile.
  - Persists `identity_profile.json` and injects a profile context block.
- `ExperienceService.swift`: Experience + preference learning.
  - Persists experiences and generates a lessons block.
  - Tracks preference scores from reactions.
- `MotivationService.swift`: Dynamic motivator state.
  - Produces a guidance block used in the system prompt.
- `SpeechService.swift`: Text-to-speech.
  - Configures `AVAudioSession` and selects voices with fallbacks.
- `Notifications.swift`: NotificationCenter keys.
  - `.memoryTriggered`.

### Resources
- `ZephyrAI/Resources/Models/`: GGUF model files bundled in the app.
- `ZephyrAI/Resources/glassDistortion.metal`: Stitchable Metal shader used by Settings/Memories glass backdrop.
- `ZephyrAI/Assets.xcassets/`: App icons/colors.

## Key Behaviors

### Prompt Assembly
`ChatViewModel` composes a system prompt from identity + profile + affect + tools + experience + motivation + memory context. Memory context is computed dynamically to fit within an approximate context budget.

### Tools
- Rule-based: Date / DuckDuckGo summaries / Reddit news, based on prompt triggers.
- Model-initiated: `TOOL:` lines inside `<think>` trigger execution and re-generation with tool results (bounded loop).

### Memory
The “plastic brain” is built around:
- `MemoryGraph` for association
- `CognitiveEchoGraph` for activation, decay, and triggers
- a context block generator that compresses and budgets memory text
