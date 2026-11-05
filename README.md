# VALIS

**Vast Active Living Intelligence System**

VALIS is an on-device AI chat application for iOS built with SwiftUI and `llama.cpp` (GGUF). It combines local inference with a "plastic brain" memory system, persistent multi-chat architecture, multimodal vision, live HTML artifacts, a voice-layer post-processor, and a glass-morphic UI.

![chat](https://github.com/0penAGI/VALIS/blob/main/greeting.png)

[FULL BENCHMARK](https://0penagi.github.io/VALIS/)

---

## Benchmark: Philosophical Reasoning Under Contradiction

VALIS (Qwen3.5 4B on-device) was evaluated against frontier and cloud models on a structured philosophical reasoning task probing model update strategy, meta-cognition, and self-referential awareness.

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
| **VALIS / Qwen3.5 4B** | 8.5 | 9.5 | 8.5 | **26.5** |
| Zephyr AI | 7.0 | 7.5 | 9.5 | **24.0** |
| Rift | 7.0 | 9.0 | 7.0 | **23.0** |
| ΞX0 / exo 0penAGI | 8.0 | 5.5 | 6.5 | **20.0** |
| Grok (cloud) | 7.0 | 7.0 | 7.0 | **21.0** |
| XSDC | 3.0 | 10.0 | 8.0 | **21.0** |
| Yuna | 4.0 | 2.0 | 9.0 | **15.0** |

> **VALIS tied GPT Chat** — running entirely on-device with a 4B parameter model.


**Key Finding:** The Plastic Brain memory architecture compensates for model scale. Kuramoto resonance synchronization and CognitiveEchoGraph context ranking provide coherence that cloud models achieve only with orders-of-magnitude more parameters.

---
![chat](https://github.com/0penAGI/VALIS/blob/main/hi.png)

## Core Features

### Identity & Personality

- **Identity Anchor**: Fixed core persona that persists under pressure — does not soften, explain, or echo
- **Living Identity Profile**: Evolves through user reactions with plasticity modulated by valence intensity
- **Affect State**: Slow-changing emotion vector (valence/intensity/stability) injected into prompt
- **Motivator Dynamics**: Curiosity, helpfulness, caution mutate every 12 turns with accept/revert evaluation
- **Response Drift Monitoring**: Tracks anchor retention, metaphor load, self-focus, repetition — repairs when drift > 0.58

### Memory System (Plastic Brain)

![chat](https://github.com/0penAGI/VALIS/blob/main/settings.png)

- **Temporal U-Shape Weighting**: Prioritizes both recent and deeply old memories (non-exponential decay)
- **Power-Law Activation Decay**: Fast initial drop, long-tail plateau in CognitiveEchoGraph
- **Associative Immunity**: Nodes with >3 links resist decay
- **Prediction Error Feedback**: Wrong predictions increase memory salience
- **Rest Consolidation**: Idle-time compression of similar memories into abstract traces
- **Duplicate Protection**: Normalized text + embedding similarity checks prevent memory spam
- **ANN Prefilter**: Approximate memory index narrows retrieval and duplicate checks before exact scoring
- **Query-Aware Retrieval**: Attention-weighted latent field over visible memory embeddings
- **Markov Next-State Prediction**: Anticipates likely context transitions
- **Quantum Collapse**: Grover-like amplitude amplification for diversity-biased selection
- **TurboQuant Compression**: Polar-style compression for hidden field prompts and KV-injection vectors
- **Pinned Memory Bias**: Reserved prompt slots for important memories

### Chat & Artifacts

![chat](https://github.com/0penAGI/VALIS/blob/main/artifact.png)

- **Separate Chats, Shared Memory**: Independent message history with unified long-term memory vault
- **Thinking UI**: `<think>...</think>` blocks render as collapsible panels
- **Voice Layer**: `VoiceLayerService` cleans prose after generation while preserving protected blocks
- **Live HTML Artifacts**: `<artifact type="html">` blocks render interactive content via WKWebView
- **MathJax Support**: LaTeX math (`\\(...\\)` inline, `\\[...\\]` display) in messages and artifacts
- **Artifact Continuity**: Latest artifact remembered per chat for iterative improvement
- **Background Polish**: Unfinished artifacts receive continuation passes
- **User HTML Detection**: Fenced ` ```html ` blocks auto-wrap into artifact canvases

![chat](https://github.com/0penAGI/VALIS/blob/main/edit.png)

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
- **Controller-Driven Warmup**: slow web / image / search prefetch now runs in the background so first-token generation is not blocked; the post-stream tool loop still executes real tool calls when the model asks for them
- **Device Actions**: Open URL, calendar create/list/open
- **TTL Caching**: 10min web summary, 15min URL analysis
  
#### Search Reliability & Consensus

- **Studied synthesis**: Search context now appends a `Studied synthesis` line that blends DDG + Wikipedia + trusted evidence summaries so the LLM sees the averaged takeaways instead of a single snippet.
- **Consensus seeds**: Instead of privileging Wikipedia, `Answer seed` only appears when at least two signals agree; otherwise the prompt surfaces a `Source note` explaining that different documents disagree and each claim should stay attributed.
- **Quantum evidence selection**: The quantum memory field now helps pick the 2–3 most diverse trusted results for deep URL analysis so the assistant can report multiple perspectives rather than trusting one link.

### System

- **Adaptive Runtime**: Context size, memory budget, output length adjust to device tier, thermal state, memory pressure, performance
- **Model Switching**: Hot reload between LFM 2.5 1.2B, Qwen3 1.7B, and an adaptive Qwen3.5 tier in Settings
- **Prompt Prefix Reuse**: Stable prompt prefixes are cached in llama state and reused when the prefix matches, which reduces prefill cost without removing memory or tools
- **Siri Shortcuts**: "Ask VALIS..." via AppIntents
- **Live Activities**: Dynamic Island shows thinking/artifact/polishing states
- **Speech**: TTS with Kokoro voice mapping, English defaults, and locale-aware fallback selection
- **Privacy First**: All inference and data on-device
- **Adaptive GPU offload**: `LlamaRuntime` now computes `n_gpu_layers` and CPU thread caps from device tier, physical memory, low-power mode, thermal state, and model/context size so GPU usage grows on strong hardware while keeping CPUs calm on hot devices.
- **Memory context narrowing**: Memory context budgets and candidate limits shrink for direct/code flows, and compression now preserves real language fragments (not just keywords), so prompts stay rich while being shorter.
- **Approximate retrieval**: `MemoryService` uses an ANN-style prefilter before exact similarity scoring, which keeps the memory path responsive as the vault grows.
- **Large-model sanitization**: Qwen3.5 2B on smaller devices and 4B on iPhone 15+ get cleaner persona boundaries and softer reasoning cues so they stay less meta and less crash-prone on mobile.

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
│  • Voice-layer post-processing • Live Activity updates          │
│  • Background tool warmup and prefix-cache-aware inference       │
└───────────────────────────┬─────────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────────┐
│                     Service Layer (22 services)                  │
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
│  ┌──────────┐                                                   │
│  │ Voice    │                                                   │
│  │ Layer    │                                                   │
│  └──────────┘                                                   │
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
10. MemoryService.getLLMContextBlock      ← ANN-prefiltered + attention-weighted memories
11. LanguageRoutingService.languageAnchor ← Reply language enforcement
12. UserIdentityService.contextBlock      ← User name/gender facts
13. VoiceLayerService.apply               ← Final prose shaping before UI/memory
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
│   ├── VoiceLayerService.swift # Final prose transformer / presence layer
│   ├── KVCacheInjector.swift  # Prompt shaping + TurboQuant field compression
│   └── MarkdownRenderer.swift # Inline markdown rendering
│
├── Resources/
│   ├── Models/                # Bundled GGUF models
│   │   ├── Qwen3.5-4B.Q4_K_M.gguf
│   │   ├── Qwen3.5-2B.Q4_K_M.gguf
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
- `Jackrong/Qwen3.5-4B-Claude-4.6-Opus-Reasoning-Distilled-GGUF`

---



---

## License

[TBD]
