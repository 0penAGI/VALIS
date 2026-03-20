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
- `index.html`: Standalone benchmark page (Philosophical Reasoning Under Contradiction) used for the README benchmark section.
- `IMG_8565.png`, `IMG_9344.png`, `IMG_8567.png`: Screenshot assets currently referenced by `README.md`.
- `IMG_8566.png`: Additional local screenshot asset.

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
- `LLMModel.swift`: Model profile registry + persistence (`LFM 2.5`/`Qwen 3`) and model-change notification.
- `QuantumFeatures.swift`: Feature flags (UserDefaults keys) for quantum memory search + snippet parser toggles.

### ViewModels (`ZephyrAI/ViewModels/`)

- `ChatViewModel.swift`: Orchestration layer.
  - Builds the system prompt from multiple context blocks:
    - `IdentityService` persona prompt
    - `IdentityProfileService` “living identity” block
    - `EmotionService` internal affect block
    - tool/action context supplied by `ActionService`
    - `ExperienceService` lessons + preferences
    - `MotivationService` guidance
    - `CodeCoachService` coding-quality guidance (on coding prompts)
    - response detail level / style tuning
  - Streams generation and parses `<think>...</think>` for the “Thinking UI”.
  - Tooling:
    - delegates rule-based tools + model-initiated `TOOL:`/`ACTION:` calls to `ActionService`.
    - re-runs generation with tool/action results (bounded multi-step loop).
    - injects `CodeCoachService` into both first-pass and tool-rerun prompts when coding intent is detected.
  - Memory + autonomy:
    - stores experiences and updates memory
    - remembers latest HTML artifact and injects it for follow-up “improve/patch artifact” turns
    - for artifact-generation prompts: uses a cleaner prompt context + higher output budget, then runs a self-check pass that patches the current artifact (and keeps the draft if the self-check tries to rewrite from scratch)
    - runs periodic self-reflection (`selfReflectionIntervalTurns`) and stores reflection traces in memory
    - applies reflection storage gating to reduce noisy self-referential memory writes
    - listens to `.memoryTriggered` and can perform a spontaneous “learn” response when idle.
  - Speech:
    - speech-to-text transcription pipeline (SFSpeechRecognizer).

### Views (`ZephyrAI/Views/`)

- `ChatView.swift`: Main chat UI (messages + streaming output + input + mic recording).
  - Parses and renders inline `<artifact type="html">...</artifact>` blocks in assistant/user bubbles.
  - Message context menus include:
    - `Edit message` for user messages (then regenerate assistant response from that turn),
    - `Regenerate` for assistant messages.
- `ArtifactView.swift`: `WKWebView` wrapper used by chat bubbles to render HTML/CSS/JS artifacts.
- `SettingsView.swift`: Persona prompt editor + navigation to Memories; presented as a translucent sheet over chat.
  - Stores optional user identity fields (name/gender) via `UserIdentityService` keys.
- `MemoryListView.swift`: Memory management UI (pin/unpin/delete/edit, clear confirmations).

### Services (`ZephyrAI/Services/`)

- `LLMService.swift`: High-level LLM interface.
  - Uses selected model profile from `LLMModelStorage` (`filename` + download URL).
  - Resolves the GGUF model in this order:
    - `Application Support/VALIS/` (download location)
    - app bundle (`ZephyrAI/Resources/Models/`)
    - `Documents/` (legacy/manual drop-in)
  - If the model is missing and a download URL is configured, downloads it (with progress) and then loads it.
  - Streams output and supports cancellation.
  - Uses `MemoryService.getContextBlock(maxChars:)` to inject a bounded memory context.
  - Uses a larger default `n_ctx` (clamped to the model's `n_ctx_train` by `LlamaRuntime`).
  - Supports per-request generation options used by artifact generation:
    - disable memory/hidden-prefix/KV-injection and caching to keep prompt context clean,
    - raise output budget (`maxTokensOverride`) for long HTML/code artifacts,
    - optionally skip storing responses back into memory for code-heavy outputs.
  - Stores one “cognitively relevant” sentence back into memory.
- `UserIdentityService.swift`: Small user identity context helper (name/gender) injected into the system prompt with guardrails.
- `LanguageRoutingService.swift`: NaturalLanguage-based language detection; emits a language anchor for short/noisy prompts and caches last confident language.
- `LlamaRuntime.swift`: `llama.cpp` wrapper.
  - Loads the model, clamps `n_ctx` to the model’s `n_ctx_train`, and provides streaming generation.
  - Includes resilience for decode failures by trimming/splitting decode batches.
- `KVCacheInjector.swift`: Helpers for prompt/context shaping for llama runtime (KV-cache/prompt hygiene utilities).
- `MarkovMemoryLayer.swift`: Lightweight Markov transition model over turns used to predict likely next “states” for memory/context selection.
- `QuantumMemoryService.swift`: Optional diversity-biased “collapse” selector for memory candidates (motivator-modulated).
- `MemoryService.swift`: “Plastic Brain” memory system.
  - Stores/persists `Memory` objects (emotion, importance, embeddings, associative links, activation/decay).
  - Maintains a graph (`MemoryGraph`) and echo/trigger logic (`CognitiveEchoGraph`).
  - Uses temporal U-shape weighting for context relevance (recently revisited + deep older memory revival).
  - Uses power-law echo activation decay (sharp early drop, long-tail plateau).
  - Applies associative-link immunity multiplier for highly connected nodes (>3 links) during decay.
  - Runs idle rest-phase consolidation: compresses highly similar memories into abstract `[rest-consolidated]` traces.
  - Deduplicates external memory ingestion (normalized exact match + embedding near-duplicate check over recent window).
  - Applies prediction-feedback learning where prediction mismatch increases retained importance and accumulated prediction error.
  - Uses a novelty-adaptive context gate to filter low-signal memories before building `getContextBlock()`.
  - Uses Markov next-state prediction and optional quantum collapse to pick a diverse, high-signal context set.
  - Provides pruning, activation/decay, and a context block generator.
- `ActionService.swift`: Tool/action runtime.
  - Parses model-initiated `TOOL:` / `ACTION:` lines.
  - Executes rule-based signals (Date / DuckDuckGo / Reddit / URL analysis) and user-visible actions (`open_url`, `calendar` open/create/list).
  - Supports URL analysis tool:
    - `TOOL: analyze_url | url=https://...`
    - automatic link detection in user prompt with page summary injection.
  - Caches repeated web signals:
    - web summary cache (TTL 10 min)
    - URL analysis cache (TTL 15 min)
  - Provides autonomous DDG/Wikipedia enrichment for spontaneous memory-triggered runs.
- `CodeCoachService.swift`: Coding-quality meta-layer.
  - Activates on code/debug/refactor/test prompts.
  - Injects guardrails for correctness, safe input handling, realistic API usage, and testability.
  - Adapts strictness to selected detail level.
- `EmotionService.swift`: Internal affect state.
  - Maintains a slow-changing (valence/intensity/stability) state with decay.
  - Provides a self-access context block intended to be referenced sparingly.
- `AutonomousMemorySources.swift`: Optional external snippet fetchers.
  - `DuckDuckGoSource`, `WikipediaSource`.
- `IdentityService.swift`: Persona prompt storage/migration.
- `IdentityProfileService.swift`: Versioned “living identity” profile (persists `identity_profile.json`).
- `ExperienceService.swift`: Experience + preference learning (lessons block, reaction tracking).
- `MotivationService.swift`: Dynamic motivator state (guidance block).
  - Maintains compact goal set (`understand`, `uncertainty`, `evolution`) and per-turn reward.
  - Runs safe personality mutation cycle (small jitter + reward-window accept/revert).
- `SpeechService.swift`: Text-to-speech helpers (AVAudioSession + voice selection).
- `Notifications.swift`: NotificationCenter keys (e.g. `.memoryTriggered`).

### Resources (`ZephyrAI/Resources/`)

- `ZephyrAI/Resources/Models/`: Bundled GGUF models (optional; app can also download to Application Support).
  - `Qwen3-1.7B-Q4_K_M.gguf`
  - `LFM2.5-1.2B-Thinking-Q8_0.gguf`
- `ZephyrAI/Resources/glassDistortion.metal`: Stitchable Metal shader for the “liquid glass” backdrop in Settings/Memories.
- `ZephyrAI/Assets.xcassets/`: App icons/colors.

## Key Behaviors

### Prompt Assembly

`ChatViewModel` composes a system prompt from identity + profile + affect + tools + experiences + motivators + code-coach guidance + bounded memory context. Memory context size is budgeted to fit within the effective context window.

### Tools

- Rule-based: Date / DuckDuckGo summaries / Reddit news / URL analysis (when links are present), based on prompt triggers.
- Model-initiated: `TOOL:`/`ACTION:` lines inside `<think>` trigger `ActionService` execution and a bounded re-generation loop.
- Duplicate suppression: repeated web snippets are filtered before being persisted as memories.
- Inline artifacts: assistant may embed `<artifact type="html" title="...">...</artifact>` in final response; chat UI extracts and renders it as a live web artifact.

### Model Storage / Download

If no model is found in the bundle, Documents, or Application Support, `LLMService` can download a model from a configured URL and store it in `Application Support/VALIS/` for future launches.
