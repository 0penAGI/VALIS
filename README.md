# VALIS

**Vast Active Living Intelligence System**

VALIS is an on-device AI chat application for iOS built with SwiftUI and `llama.cpp` (GGUF). It combines local inference with a "plastic brain" memory system, persistent multi-chat architecture, multimodal vision, live HTML artifacts, and a glass-morphic UI.

![chat](https://github.com/0penAGI/VALIS/blob/main/IMG_8565.png)

[FULL BENCHMARK](https://0penagi.github.io/VALIS/)

---

## Benchmark: Philosophical Reasoning Under Contradiction

VALIS (Qwen3 1.7B on-device) was evaluated against frontier and cloud models on a structured philosophical reasoning task probing model update strategy, meta-cognition, and self-referential awareness.

**Test Question:**
> *"A system receives a signal that contradicts its current model. Both data points are correct. What matters more: preserve internal consistency or update the model? And who in the system makes that decision — and does it know it's making it?"*

Models scored on three axes: **Philosophical Depth**, **Structural Clarity**, **Existential Honesty**.

```
PHILOSOPHICAL DEPTH
         10
          |
   GPT ●  |  ● VALIS
          |
   Zephyr |
        ● |
──────────┼──────────  EXISTENTIAL HONESTY
          |       10
    Rift  |
        ● |
          |
   Grok ● |
          |
```

### Composite Scores

| Model | Phil. Depth | Structural Clarity | Exist. Honesty | **Total** |
|-------|-------------|-------------------|----------------|-----------|
| GPT Chat (cloud) | 9.5 | 9.0 | 8.0 | **26.5** |
| **VALIS / Qwen3 1.7B** | 8.5 | 9.5 | 8.5 | **26.5** |
| Zephyr AI | 7.0 | 7.5 | 9.5 | **24.0** |
| Rift | 7.0 | 9.0 | 7.0 | **23.0** |
| ΞX0 / exo 0penAGI | 8.0 | 5.5 | 6.5 | **20.0** |
| Grok (cloud) | 7.0 | 7.0 | 7.0 | **21.0** |
| XSDC | 3.0 | 10.0 | 8.0 | **21.0** |
| Yuna | 4.0 | 2.0 | 9.0 | **15.0** |

> **VALIS tied GPT Chat** — running entirely on-device with a 1.7B parameter model.

**Key Finding:** The Plastic Brain memory architecture compensates for model scale. Kuramoto resonance synchronization and CognitiveEchoGraph context ranking provide coherence that cloud models achieve only with orders-of-magnitude more parameters.

---

## Core Features

### Identity & Personality

- **Identity Anchor**: Fixed core persona that persists under pressure — does not soften, explain, or echo
- **Living Identity Profile**: Evolves through user reactions with plasticity modulated by valence intensity
- **Affect State**: Slow-changing emotion vector (valence/intensity/stability) injected into prompt
- **Motivator Dynamics**: Curiosity, helpfulness, caution mutate every 12 turns with accept/revert evaluation
- **Response Drift Monitoring**: Tracks anchor retention, metaphor load, self-focus, repetition — repairs when drift > 0.58

### Memory System (Plastic Brain)

- **Temporal U-Shape Weighting**: Prioritizes both recent and deeply old memories (non-exponential decay)
- **Power-Law Activation Decay**: Fast initial drop, long-tail plateau in CognitiveEchoGraph
- **Associative Immunity**: Nodes with >3 links resist decay
- **Prediction Error Feedback**: Wrong predictions increase memory salience
- **Rest Consolidation**: Idle-time compression of similar memories into abstract traces
- **Duplicate Protection**: Normalized text + embedding similarity checks prevent memory spam
- **Query-Aware Retrieval**: Attention-weighted latent field over visible memory embeddings
- **Markov Next-State Prediction**: Anticipates likely context transitions
- **Quantum Collapse**: Grover-like amplitude amplification for diversity-biased selection
- **Pinned Memory Bias**: Reserved prompt slots for important memories

### Chat & Artifacts

- **Separate Chats, Shared Memory**: Independent message history with unified long-term memory vault
- **Thinking UI**: `<think>...</think>` blocks render as collapsible panels
- **Live HTML Artifacts**: `<artifact type="html">` blocks render interactive content via WKWebView
- **MathJax Support**: LaTeX math (`\\(...\\)` inline, `\\[...\\]` display) in messages and artifacts
- **Artifact Continuity**: Latest artifact remembered per chat for iterative improvement
- **Background Polish**: Unfinished artifacts receive continuation passes
- **User HTML Detection**: Fenced ` ```html ` blocks auto-wrap into artifact canvases

### Multimodal Vision

- **OCR**: English/Russian text recognition via Vision
- **Face Detection**: Rectangles + landmarks (eyes, nose, lips, eyebrows, contour)
- **Object Detection**: Core ML integration (YOLO, MobileNet)
- **Similar Image Retrieval**: Vision feature prints + quantum collapse

### Tools & Actions

- **Rule-Based Tools**: Auto-injected on trigger patterns
  - `date`: Current date/time
  - `web_search`: DuckDuckGo Instant Answer
  - `reddit_news`: Reddit /r/news feed
  - `analyze_url`: Webpage content summary
- **Model-Initiated Tools**: `TOOL:` / `ACTION:` parsing with bounded re-execution loop
- **Device Actions**: Open URL, calendar create/list/open
- **TTL Caching**: 10min web summary, 15min URL analysis

### System

- **Adaptive Runtime**: Context size, memory budget, output length adjust to device tier, thermal state, memory pressure, performance
- **Model Switching**: Hot reload between LFM 2.5 1.2B and Qwen3 1.7B in Settings
- **Siri Shortcuts**: "Ask VALIS..." via AppIntents
- **Live Activities**: Dynamic Island shows thinking/artifact/polishing states
- **Speech**: TTS with locale-aware voice selection
- **Privacy First**: All inference and data on-device

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     SwiftUI App Layer                            │
│  ChatView │ SettingsView │ MemoryListView │ ArtifactView        │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                  ChatViewModel (Orchestrator)                    │
│  • System prompt assembly  • Streaming + thinking UI parsing    │
│  • Tool/action execution   • Memory management & reflection     │
│  • Chat session persistence • Image attachment analysis         │
│  • Live Activity updates                                        │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                     Service Layer (21 services)                  │
│  ┌──────────┐ ┌───────────┐ ┌────────────┐ ┌─────────────────┐  │
│  │ LLM      │ │ Memory    │ │ Action     │ │ Emotion         │  │
│  │ Service  │ │ Service   │ │ Service    │ │ Service         │  │
│  └──────────┘ └───────────┘ └────────────┘ └─────────────────┘  │
│  ┌──────────┐ ┌───────────┐ ┌────────────┐ ┌─────────────────┐  │
│  │ Identity │ │ Experience│ │ Motivation │ │ Vision          │  │
│  │ Service  │ │ Service   │ │ Service    │ │ Attachment      │  │
│  └──────────┘ └───────────┘ └────────────┘ └─────────────────┘  │
│  ┌──────────┐ ┌───────────┐ ┌────────────┐ ┌─────────────────┐  │
│  │ Quantum  │ │ Code      │ │ Response   │ │ Speech          │  │
│  │ Memory   │ │ Coach     │ │ Drift      │ │ Service         │  │
│  └──────────┘ └───────────┘ └────────────┘ └─────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                  llama.cpp Runtime Layer                         │
│  LlamaRuntime │ KVCacheInjector │ LanguageRouting               │
└─────────────────────────────────────────────────────────────────┘
```

---

## System Prompt Assembly

```
1. IdentityService.systemPrompt           ← Master persona + tool instructions
2. IdentityProfileService.contextBlock    ← 3-word identity state (e.g. "alive curious adaptive")
3. EmotionService.contextBlock            ← Valence/intensity/stability
4. ActionService.buildToolGuidanceBlock   ← Available actions
5. ExperienceService.contextBlock         ← Lessons + preferences
6. MotivationService.contextBlock         ← C,H,Z,M,T,E + goals + reward
7. MotivationService.trajectoryGuidance   ← Response style guidance
8. CodeCoachService.contextBlock          ← Coding guardrails (if applicable)
9. ResponseDriftService.contextBlock      ← Drift monitor (anchor/metaphor/self/repetition)
10. MemoryService.getLLMContextBlock      ← Retrieved memories (attention-weighted)
11. LanguageRoutingService.languageAnchor ← Reply language enforcement
12. UserIdentityService.contextBlock      ← User name/gender facts
```

---

## Project Structure

```
ZephyrAI/
├── ZephyrAIApp.swift          # App entry + Siri Shortcuts
├── ContentView.swift          # Root navigation
├── Persistence.swift          # Core Data stack
├── memories.json              # Pre-seeded memories
├── ZephyrAI-Bridging-Header.h # llama.cpp imports
├── ZephyrAI.entitlements      # App sandbox
│
├── Models/
│   ├── Message.swift          # Chat message + attachments
│   ├── LLMModel.swift         # Model profiles + download URLs
│   └── QuantumFeatures.swift  # Feature flags
│
├── ViewModels/
│   └── ChatViewModel.swift    # Central orchestrator (3345 lines)
│
├── Views/
│   ├── ChatView.swift         # Main chat UI + MathJax (2339 lines)
│   ├── ArtifactView.swift     # WKWebView for HTML + MathJax
│   ├── SettingsView.swift     # Settings sheet + glass shader
│   ├── MemoryListView.swift   # Memory vault UI
│   └── IntroGreetingView.swift # Procedural greeting animation
│
├── Services/
│   ├── LLMService.swift       # LLM orchestration (907 lines)
│   ├── LlamaRuntime.swift     # llama.cpp wrapper
│   ├── MemoryService.swift    # Plastic Brain (2547 lines)
│   ├── QuantumMemoryService.swift # Diversity-biased retrieval
│   ├── MarkovMemoryLayer.swift # State transition prediction
│   ├── ActionService.swift    # Tools/actions (1561 lines)
│   ├── IdentityService.swift  # Master persona prompt
│   ├── IdentityProfileService.swift # Living identity versioning
│   ├── EmotionService.swift   # Affect state vector
│   ├── MotivationService.swift # Agent dynamics + mutation
│   ├── ExperienceService.swift # Learning from reactions
│   ├── ResponseDriftService.swift # Quality monitoring
│   ├── CodeCoachService.swift # Coding guardrails
│   ├── VisionAttachmentService.swift # Image analysis
│   ├── SpeechService.swift    # TTS
│   ├── LanguageRoutingService.swift # Language detection
│   ├── UserIdentityService.swift # User facts
│   ├── AutonomousMemorySources.swift # DDG/Wiki fetchers
│   ├── KVCacheInjector.swift  # Prompt shaping
│   └── MarkdownRenderer.swift # Inline markdown rendering
│
├── Resources/
│   ├── Models/                # Bundled GGUF models
│   │   ├── Qwen3-1.7B-Q4_K_M.gguf
│   │   └── LFM2.5-1.2B-Thinking-Q8_0.gguf
│   └── glassDistortion.metal  # Glass shader
│
└── Assets.xcassets/           # App icons/colors
```

---

## Requirements

- Xcode 16+ (iOS 18.5 deployment target)
- `Frameworks/llama.xcframework`
- GGUF model (bundled or downloaded)

## Quick Start

1. Ensure `Frameworks/llama.xcframework` exists
2. Models: bundle in `ZephyrAI/Resources/Models/` or rely on first-run download
3. Build and run `ZephyrAI.xcodeproj` on device

## Model Download

`LLMService` searches in order:
1. `Application Support/VALIS/` (download location)
2. App bundle
3. `Documents/`

Download URLs (HuggingFace - unsloth):
- `unsloth/LFM2.5-1.2B-Thinking-GGUF`
- `unsloth/Qwen3-1.7B-GGUF`

---

## Screenshots

![chat](https://github.com/0penAGI/VALIS/blob/main/IMG_9344.png)
![chat](https://github.com/0penAGI/VALIS/blob/main/IMG_8567.png)

---

## License

[TBD]
