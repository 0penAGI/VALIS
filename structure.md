# VALIS Project Structure

This document provides a detailed overview of the VALIS repository structure.

## Root Directory

- **ZephyrAI/**: Main application source code and resources.
- **Frameworks/**: Contains local binary frameworks.
  - `llama.xcframework`: The pre-compiled llama.cpp framework for iOS/macOS.
- **ZephyrAI.xcodeproj**: The Xcode project file for the iOS app target and tests.
- **AnyLanguageModel/**: Upstream Swift package vendored into the repo. Not wired into the current VALIS app target, but shows how to talk to multiple language model backends (Apple Foundation Models, Core ML, MLX, llama.cpp, and remote APIs) from Swift.
- **mlx-swift/**: Upstream MLX Swift repository vendored as a subfolder. Useful as a reference and potential future backend for on-device ML; not linked into the current VALIS target.
- **README.md**: Project documentation.
- **structure.md**: This file.

## Application Source (`ZephyrAI/`)

The core application logic is contained within the `ZephyrAI` directory.

### App Entry
- `ZephyrAIApp.swift`: The SwiftUI application entry point.
- `ContentView.swift`: The root view of the application.

### Services (`ZephyrAI/Services/`)
This directory contains the core business logic and backend services.

- **LLMService.swift**: The central service for Language Model interaction.
  - Manages the `LlamaRuntime` instance.
  - Handles prompt assembly and response generation.
  - Implements a short-term response cache (`NSCache`).
  - Contains logic for scoring and selecting "cognitively relevant" sentences.
  - Injects the `MemoryService` context block (compressed memories, emotional tone, and raw summaries) directly into the system prompt.
- **LlamaRuntime.swift**: Swift bindings for the underlying `llama.cpp` library. Handles token generation.
  - Tokenizes prompts and decodes them in batches to avoid `llama_decode` failures when prompts exceed batch limits.
  - Trims overly-long prompts to fit within context constraints.
- **MemoryService.swift**: Manages the application's long-term memory and cognitive architecture.
  - Stores `Memory` objects with embeddings, emotions, and importance scores.
  - Maintains `MemoryGraph` and `CognitiveEchoGraph` for associative memory retrieval.
  - Runs background loops:
    - Echo loop: activation decay + low-level spontaneous activation.
    - Spontaneous loop: selects a “charged” memory node and may trigger autonomous consolidation + retention pruning.
  - Can consolidate from external sources (optional network) when a memory is triggered.
  - Builds the context block that `LLMService` consumes: compressed memories, prediction score/error, emotional distribution with guidance, and a bounded list of raw recent memories so the assistant can remember “what just happened” without overflowing the prompt size.
  - Seeds **Identity Nodes** (core/beliefs/self) with zero decay so the persona persists across sessions.
  - Applies prediction feedback (score/error) to the most recent memory to support future predictive processing.
- **AutonomousMemorySources.swift**: Pluggable external sources for autonomous memory consolidation.
  - `WikipediaSource`: Uses the Wikipedia REST “page summary” endpoint.
  - `DuckDuckGoSource`: Uses DuckDuckGo Instant Answer API summaries.
- **IdentityService.swift**: Manages the AI's persona and system prompt.
  - Persists the current identity prompt and teaches the model to request `TOOL: web_search | <query>` or `TOOL: date` when it needs fresh facts.
- **SpeechService.swift**: Handles speech-to-text and text-to-speech functionality (if enabled).
- **Notifications.swift**: NotificationCenter event names used for cross-layer signaling.
  - `memoryTriggered`: published when the echo graph crosses a trigger threshold.
- **ExperienceService.swift**: Captures exchanges as structured “experience” records.
  - Persists `experiences.json` with outcome + reflection + user reaction.
  - Learns user preference signals and stores `user_preferences.json`.
  - Provides a lessons block for the system prompt.
- **MotivationService.swift**: Maintains dynamic motivators (curiosity/helpfulness/caution) based on prompt/reactions.
  - Injects a guidance block into the system prompt.

### ViewModels (`ZephyrAI/ViewModels/`)
- **ChatViewModel.swift**: The main view model for the chat interface.
  - Acts as the **Agent Orchestration Layer**.
  - Implements a Rule Engine to decide when to use tools (Web Search, Date).
  - Applies reinforcement from user tone, streams `<think>` via `ThinkStreamParser`, and re-invokes `LLMService` when `TOOL:` lines request a search or the date.
  - Aggregates context from tools and memory before sending to `LLMService`.
  - Adds experience lessons + motivators into the system prompt.
  - Records experiences after each assistant response and learns preferences from reactions.
  - Parses `<think>` tags from the model output for the "Thinking UI".
  - Listens for `memoryTriggered` and can initiate a spontaneous “learning” response when the chat is idle.

### Views (`ZephyrAI/Views/`)
- **ChatView.swift**: The main chat interface. Displays the message list, input field, and "Thinking" panel.
  - Long‑press context menu includes copy, speak, and like/dislike for assistant messages.
- **MemoryListView.swift**: A debug/management view for inspecting and modifying stored memories.
- **SettingsView.swift**: Application settings.

### Models (`ZephyrAI/Models/`)
- **Message.swift**: Data model representing a chat message.

### Resources (`ZephyrAI/Resources/`)
- **Models/**: Directory for storing GGUF model files (e.g., `LFM2.5-1.2B-Thinking-Q8_0.gguf`).
- **Assets.xcassets/**: App icons and colors.

## Key Concepts

### Agent Orchestration
The `ChatViewModel` serves as a lightweight router. It analyzes user input for specific triggers (e.g., "search", "date") to fetch external context (via DuckDuckGo or system time) before invoking the LLM.

### Cognitive Architecture ("Plastic Brain")
The `MemoryService` implements a dynamic memory system where memories are not just static records but nodes in a graph that can be activated based on emotional context and associative links. Prediction signals (score/error) are stored per memory, and Identity Nodes are pinned with zero decay to stabilize the self-model.

### Autonomous Memory / Endogenous Activity
The app can create “endogenous” activity via the echo graph. When a memory node becomes highly activated, it emits `memoryTriggered`, allowing the app to:
- fetch short external snippets (e.g. Wikipedia, DuckDuckGo) for the most relevant topic,
- store an “autonomous” memory entry,
- periodically prune older, low-importance, low-activation memories to keep context useful.
The `MemoryService` context block continues to flow through to the live chat so those autonomously gathered snippets immediately enrich subsequent replies.
