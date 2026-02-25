# VALIS Project Structure

This document describes the repository layout and the main runtime components as reflected in the current codebase.

## Root Directory

- `ZephyrAI/`: Main iOS app target (SwiftUI).
- `ZephyrAI.xcodeproj/`: Xcode project.
- `ZephyrAITests/`, `ZephyrAIUITests/`: Test targets.
- `Frameworks/`: Local binary frameworks (not necessarily committed).
  - `llama.xcframework`: Prebuilt `llama.cpp` framework.
- `README.md`: Project overview.
- `structure.md`: This file.
- `IMG_9313.jpeg`, `IMG_9314.jpeg`, `IMG_9315.jpeg`: Screenshot assets used in the README.

### Local / Vendored Folders

These may exist locally for reference/experimentation. In this repo they are typically **ignored** or managed separately to avoid pushing large embedded repos:

- `AnyLanguageModel/`
- `mlx-swift/`
- `swift-llama-cpp/`

## App Source (`ZephyrAI/`)

### Entry
- `ZephyrAI/ZephyrAIApp.swift`: SwiftUI app entry.
- `ZephyrAI/ContentView.swift`: Root view.

### Models (`ZephyrAI/Models/`)
- `Message.swift`: Chat message model.
- (Other small data structs are defined near the services that use them.)

### ViewModels (`ZephyrAI/ViewModels/`)

- `ChatViewModel.swift`: Orchestration layer.
  - Builds the system prompt from multiple context blocks:
    - `IdentityService` persona prompt
    - `IdentityProfileService` “living identity” block
    - `EmotionService` internal affect block
    - tool context (Date / DuckDuckGo / Reddit news) when enabled/triggered
    - `ExperienceService` lessons + preferences
    - `MotivationService` guidance
    - response detail level / style tuning
  - Streams generation and parses `<think>...</think>` for the “Thinking UI”.
  - Tooling:
    - Rule-based tools: inject Date/Web/News context based on trigger phrases.
    - Model-initiated tools: parses `TOOL:` lines and re-runs generation with tool results (bounded multi-step loop).
  - Memory + autonomy:
    - stores experiences and updates memory
    - listens to `.memoryTriggered` and can perform a spontaneous “learn” response when idle.
  - Speech:
    - speech-to-text transcription pipeline (SFSpeechRecognizer).

### Views (`ZephyrAI/Views/`)

- `ChatView.swift`: Main chat UI (messages + streaming output + input + mic recording).
- `SettingsView.swift`: Persona prompt editor + navigation to Memories; presented as a translucent sheet over chat.
- `MemoryListView.swift`: Memory management UI (pin/unpin/delete/edit, clear confirmations).

### Services (`ZephyrAI/Services/`)

- `LLMService.swift`: High-level LLM interface.
  - Resolves the GGUF model in this order:
    - `Application Support/VALIS/` (download location)
    - app bundle (`ZephyrAI/Resources/Models/`)
    - `Documents/` (legacy/manual drop-in)
  - If the model is missing and a download URL is configured, downloads it (with progress) and then loads it.
  - Streams output and supports cancellation.
  - Uses `MemoryService.getContextBlock(maxChars:)` to inject a bounded memory context.
  - Stores one “cognitively relevant” sentence back into memory.
- `LlamaRuntime.swift`: `llama.cpp` wrapper.
  - Loads the model, clamps `n_ctx` to the model’s `n_ctx_train`, and provides streaming generation.
  - Includes resilience for decode failures by trimming/splitting decode batches.
- `KVCacheInjector.swift`: Helpers for prompt/context shaping for llama runtime (KV-cache/prompt hygiene utilities).
- `MemoryService.swift`: “Plastic Brain” memory system.
  - Stores/persists `Memory` objects (emotion, importance, embeddings, associative links, activation/decay).
  - Maintains a graph (`MemoryGraph`) and echo/trigger logic (`CognitiveEchoGraph`).
  - Provides pruning, activation/decay, and a context block generator.
- `EmotionService.swift`: Internal affect state.
  - Maintains a slow-changing (valence/intensity/stability) state with decay.
  - Provides a self-access context block intended to be referenced sparingly.
- `AutonomousMemorySources.swift`: Optional external snippet fetchers.
  - `DuckDuckGoSource`, `WikipediaSource`.
- `IdentityService.swift`: Persona prompt storage/migration.
- `IdentityProfileService.swift`: Versioned “living identity” profile (persists `identity_profile.json`).
- `ExperienceService.swift`: Experience + preference learning (lessons block, reaction tracking).
- `MotivationService.swift`: Dynamic motivator state (guidance block).
- `SpeechService.swift`: Text-to-speech helpers (AVAudioSession + voice selection).
- `Notifications.swift`: NotificationCenter keys (e.g. `.memoryTriggered`).

### Resources (`ZephyrAI/Resources/`)

- `ZephyrAI/Resources/Models/`: Bundled GGUF models (optional; app can also download to Application Support).
- `ZephyrAI/Resources/glassDistortion.metal`: Stitchable Metal shader for the “liquid glass” backdrop in Settings/Memories.
- `ZephyrAI/Assets.xcassets/`: App icons/colors.

## Key Behaviors

### Prompt Assembly

`ChatViewModel` composes a system prompt from identity + profile + affect + tools + experiences + motivators + bounded memory context. Memory context size is budgeted to fit within the effective context window.

### Tools

- Rule-based: Date / DuckDuckGo summaries / Reddit news, based on prompt triggers.
- Model-initiated: `TOOL:` lines inside `<think>` trigger tool execution and a bounded re-generation loop.

### Model Storage / Download

If no model is found in the bundle, Documents, or Application Support, `LLMService` can download a model from a configured URL and store it in `Application Support/VALIS/` for future launches.

