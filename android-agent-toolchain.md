# Android Agent Dev Toolchain — Capabilities

Google's official toolchain for building, running, testing, and shipping Android apps
**with** AI agents (any agent, not just Gemini).

> Claimed impact: ~70% fewer LLM tokens, ~3× faster task completion vs. standard toolsets.

**Mental model:** ADK = build agents *inside* your app · CLI + Skills + Knowledge Base +
Journeys + Lightbuild = let a coding agent build/run/test/ship the app itself.

---

## 1. Android CLI — scriptable toolchain access for agents

A single, predictable `android` command surface so agents don't have to guess at the toolchain.

| Command | Capability |
|---|---|
| `android sdk install` | Download only the specific SDK components needed (lean env) |
| `android create` | Generate new projects from official templates with recommended architecture |
| `android emulator` | Create and manage virtual devices |
| `android run` | Build and deploy apps to devices/emulators |
| `android update` | Keep tools/capabilities current |
| `android skills` | Browse and configure skill workflows |
| `android docs` | Query the Android Knowledge Base |

- Works in plain terminal and CI/CD; natural-language friendly.

## 2. Android Skills — modular expertise injected on demand

- `SKILL.md` markdown instruction sets; a technical spec for one task.
- **Auto-trigger** when a prompt matches the skill's metadata.
- Launch examples: Navigation 3 setup/migration, edge-to-edge support, AGP 9 and
  XML→Compose migrations, R8 config analysis, plus app launch & distribution skills.

## 3. Android Knowledge Base — anti-stale-training grounding

- Reached via `android docs` (and Android Studio).
- Agents search/fetch authoritative, current guidelines as context.
- Sources: Android developer docs, Firebase, Google Developers, Kotlin docs —
  regardless of model training cutoff.

## 4. Journeys for CI/CD — natural-language app validation

- Define tests ("journeys") in plain language; agent converts them to app interactions.
- **Vision-based validation**: agent looks at the screen and writes/evaluates complex
  assertions by reasoning over UI state.
- Runs via Android CLI in terminal or CI/CD pipelines; agents can both author and execute journeys.

## 5. ADK for Android (Agent Development Kit, Kotlin/Java, v0.1.0) — build agents *into* apps

- **`LlmAgent`** — core agent: model + tools + instructions; Kotlin & Java; supports multi-agent systems.
- **Tools**: `@Tool` / `@Param` annotations, `generatedTools()` exposes them; return `Map<String,String>` or structured data.
- **Cloud models**: `Gemini` class (`gemini-flash-latest`, etc.); API key via backend/Firebase AI Logic, not embedded.
- **On-device models**: `GenaiPrompt` + Gemini Nano via ML Kit — private, low-latency, offline.
- **Hybrid multi-agent**: cloud root orchestrator + on-device sub-agents for sensitive tasks.
- **Execution**: `InMemoryRunner.runAsync()` → `Flow<Event>` streaming; `Content`/`Part`/`Role` message APIs.
- **Sessions**: `InMemorySessionService` with `userId`/`sessionId` + history.
- **Setup**: `com.google.adk:google-adk-kotlin-core-android:0.1.0` + KSP processor;
  compileSdk 34+, minSdk 24+, JDK/Kotlin toolchain 17.

```kotlin
@Tool
fun getCurrentTime(
    @Param("Name of the city") city: String
): Map<String, String> { /* ... */ }
```

## 6. Lightbuild

- Purpose-built (faster) build tool for the agent loop.

## 7. Antigravity 2.0 integration

- Android CLI + Skills wired into Google's Antigravity agent IDE so agents perform
  core Android dev tasks there. https://antigravity.google/

---

## Bonus: AppFunctions (apps → agent capabilities)

The complement to the dev toolchain: AppFunctions is Android's on-device equivalent of
MCP tools. Apps declare functions (`@AppFunction`, `@AppFunctionSerializable`) that
agents/assistants discover (`AppFunctionManager`, `isAppFunctionEnabled`) and execute
locally. Callers need the `android.permission.EXECUTE_APP_FUNCTIONS` permission.

---

## Sources

- [Android agent tools & resources](https://developer.android.com/tools/agents)
- [Android CLI and skills — build apps 3× faster (blog)](https://android-developers.googleblog.com/2026/04/build-android-apps-3x-faster-using-any-agent.html)
- [Build ADK agents for Android](https://developer.android.com/ai/adk)
- [Journeys for CI/CD](https://developer.android.com/tools/agents/android-cli/journeys)
- [ADK for Kotlin & Android 0.1.0 announcement](https://developers.googleblog.com/adk-kotlin-android-building-ai-agents/)
- [AppFunctions overview](https://developer.android.com/ai/appfunctions)
