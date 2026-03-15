# Askari AI — Ranger Intelligence Copilot

> PowerSync AI Hackathon 2026 · Local-First & Offline-Capable AI

An on-device AI assistant for wildlife park rangers. All AI inference runs locally using **swift-cactus** — no connectivity required. Data syncs to Supabase via **PowerSync** when back in range.

---

## Features

| Feature | Stack |
|---------|-------|
| Natural language patrol queries | CactusAgentSession + function calling |
| Voice incident logging (STT) | CactusSTTSession + Whisper Small (NPU) |
| Pre-patrol AI briefing | CactusAgentSession + local SQLite |
| Offline-first sync | PowerSync Swift SDK → Supabase |
| Reactive UI | SwiftUI + The Composable Architecture |

---

## Project Structure

```
AskariAI/
├── App/                    # App entry point, root navigation
├── Managers/               # SystemManager, SupabaseConnector, Schema
│   ├── Schema.swift        # PowerSync local SQLite schema
│   ├── SystemManager.swift # PowerSync database + TCA dependency
│   ├── SupabaseConnector.swift
│   └── _Secrets.swift      # ← gitignored, copy from template
├── Features/               # TCA Reducers + Views (co-located)
│   ├── App/                # AppFeature, MainFeature
│   ├── Auth/               # AuthFeature
│   ├── Missions/           # MissionsFeature
│   ├── ActiveMission/      # ActiveMissionFeature (GPS tracking)
│   ├── Dashboard/          # DashboardFeature (intel overview)
│   └── Copilot/            # RangerCopilotFeature (AI chat + voice + briefing)
├── Models/                 # Codable data models
├── Views/                  # SwiftUI views
│   └── Copilot/            # CopilotChatView, AIBriefingView
└── AI/
    ├── AIManager.swift     # CactusAgentSession / STT / VAD lifecycle
    └── Tools/
        └── CactusTools.swift  # CactusFunction implementations

supabase/
└── migrations/
    ├── 001_initial_schema.sql   # Applied ✓
    └── 002_rls_policies.sql     # RLS policies

powersync/
└── sync-config.yaml  # Sync Streams config (edition 3)
```

---

## Setup

### 1. Swift Package Dependencies (Xcode SPM)

Add these to the Xcode project:

| Package | URL | Version |
|---------|-----|---------|
| PowerSync Swift SDK | `https://github.com/powersync-ja/powersync-swift` | `>= 1.0.0` |
| Supabase Swift | `https://github.com/supabase/supabase-swift` | `>= 2.0.0` |
| TCA | `https://github.com/pointfreeco/swift-composable-architecture` | `>= 1.0.0` |
| swift-cactus | `https://github.com/mhayes853/swift-cactus` | `>= 2.0.0` |

### 2. Secrets

Copy `_Secrets.template.swift` to `AskariAI/Managers/_Secrets.swift` and fill in:
- `supabaseURL`
- `supabaseAnonKey`
- `powerSyncEndpoint`

### 3. Info.plist Permissions

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for voice incident logging in the field</string>
```

### 4. PowerSync Sync Config

The sync rules are in `powersync/sync-config.yaml`. Deploy via:

```bash
npm install -g powersync
powersync login
powersync link cloud --instance-id=69b5b2687c4f8b306a1b8255 --project-id=<project-id>
powersync deploy sync-config
```

---

## Backend

- **Supabase Project:** `zingetplhjqubtydzfpo`
- **PowerSync Instance:** `https://69b5b2687c4f8b306a1b8255.powersync.journeyapps.com`
- Schema: see `supabase/migrations/`

---

## AI Models (swift-cactus)

| Model | Use | Download size |
|-------|-----|---------------|
| `lfm2_5_1_2bThinking` | LLM for query + briefing + tool calling | ~1.2 GB |
| `whisperSmall(pro: .apple)` | STT transcription (NPU-accelerated) | ~250 MB |
| `sileroVad` | Voice activity detection | ~5 MB |

Models download once to the app's Application Support directory via `CactusModelsDirectory`.
