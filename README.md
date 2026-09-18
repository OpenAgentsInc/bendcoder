# bender

Bender is a new coding agent written in **Bend2**, supplemented with C for network calls, HTTP requests, and systems interfaces missing in Bend2.

## Philosophy: Two Primitives (`Classify` & `Generate`)

Rather than dozens of ad-hoc tools, brittle parsers, and fragile conversational loops, Bender distills agent actions into two core primitives:
1. **`Classify` (System 1 - Fast, Calibrated Decision Making)**:
   - Powered by **TypeSafe System One** (`jev-latest`).
   - Evaluates state against typed questions (`Choice`, `Score`, `Noul`) to yield calibrated routing decisions, confidence, and probabilities in a single batched HTTP call.
2. **`Generate` (System 2 - Generative Synthesis)**:
   - Powered by **OpenRouter** (or any OpenAI-compatible provider like Gemini / Ollama).
   - Produces code synthesis, diff generation, and solutions when `Classify` determines generation is required.

---

## Autonomous Agent Loop & Terminal UI

Bender runs an autonomous decision loop with a live terminal UI:
```
State -> Classify (TypeSafe) -> Calibrated Action -> Tool Execution -> State Update -> Verification
```

### Running the Autonomous Loop

```bash
./run_bender.sh
```

Example run session:
```text
================================================================================
  🤖 [BENDER] Autonomous Coding Agent (Bend2 + TypeSafe + OpenRouter)
================================================================================
🎯 [GOAL] Initial Objective: Inspect repository, verify hello.bend, and confirm autonomous capabilities...

--------------------------------------------------------------------------------
📍 [STEP 1] Classifying State with TypeSafe System One (Jev)...
--------------------------------------------------------------------------------
🧠 [Classify Decision]: read_code (Confidence: 0.82, Probability: 0.87)
📖 [TOOL READ] Reading 'hello.bend'...

--------------------------------------------------------------------------------
📍 [STEP 2] Classifying State with TypeSafe System One (Jev)...
--------------------------------------------------------------------------------
🧠 [Classify Decision]: run_build (Confidence: 0.98, Probability: 0.98)
⚡ [TOOL EXEC] Running 'bend hello.bend'...
   Output: Hello, world!

--------------------------------------------------------------------------------
📍 [STEP 3] Classifying State with TypeSafe System One (Jev)...
--------------------------------------------------------------------------------
🧠 [Classify Decision]: task_complete (Confidence: 0.73, Probability: 0.79)
✅ [TASK COMPLETE] Bender confirmed all goals are verified and complete!
================================================================================
```

---

## Quickstart: Hello World

### Prerequisites

Ensure you have Bend installed (Bend 2.0+):

```bash
bend --version
```

### Running Hello World

```bash
bend hello.bend
```

Output:
```
Hello, world!
```

---

## Agent Primitives: `Classify` & `Generate`

Defined in `agent_primitives.bend`:
- `Classify(state: String, questions: List<&2, Question>) -> IO(String)`
- `Generate(model: String, system_prompt: String, prompt: String) -> IO(String)`

### Running the Primitives Pipeline

```bash
./run_agent_primitives.sh
```

---

## API Keys & Configuration

Both keys are git-ignored and can be set in files or environment variables:

### 1. TypeSafe System One (for `Classify`)
- **File:** `.env.typesafe` (template: `.env.typesafe.example`)
- **Env Var:** `TYPESAFE_API_KEY`
- **Standalone cURL test:**
  ```bash
  ./call_typesafe.sh
  ```

### 2. OpenRouter (for `Generate`)
- **File:** `.env.openrouter` (template: `.env.openrouter.example`)
- **Env Var:** `OPENROUTER_API_KEY`
- **Standalone cURL test:**
  ```bash
  ./call_openrouter.sh
  ```
