# bender

Bender is a new coding agent written in **Bend2**, supplemented with C for network calls, HTTP requests, and any other systems interfaces missing in Bend2.

## Quickstart: Hello World

### Prerequisites

Ensure you have Bend installed (Bend 2.0+):

```bash
bend --version
```

### Running the Example

Run the basic `hello.bend` program with the `bend` CLI:

```bash
bend hello.bend
```

Output:
```
Hello, world!
```

### Compiling to a Binary or C

You can also compile `hello.bend` to a native binary:

```bash
bend hello.bend -o hello
./hello
```

Or emit C source code:

```bash
bend hello.bend -o hello.c
```

---

## TypeSafe AI HTTP / System One Integration

Bender interacts with the TypeSafe AI System One API (`https://api.typesafe.ai/v1/systemone`) for structured evaluation questions (`noul`, `choice`, `score`).

### API Key Configuration

The API key is loaded from the environment or a configuration file:
- **File:** `.env.typesafe` (in the root directory, ignored by git)
  - Replace `YOUR_TYPESAFE_API_KEY` with your actual TypeSafe API key.
- **Environment Variable:** `TYPESAFE_API_KEY`

### 1. Direct cURL Example (`call_typesafe.sh`)

Test the endpoint directly via curl:

```bash
./call_typesafe.sh
```

This sends an evaluation request with:
- State: Customer ticket describing payout failures.
- Questions:
  - `is_urgent`: Noul (urgency probability)
  - `department`: Choice (billing, technical, sales)
  - `frustration`: Score (Calm, Frustrated, Very angry)

### 2. Bend2 + C FFI Example (`call_typesafe.bend`)

This demonstrates Bend2 dispatching an IO effect handled by C (`typesafe_c.c`):

```bash
./run_bend_typesafe.sh
```

Or step by step:
```bash
bend call_typesafe.bend -o call_typesafe.c
gcc -std=c11 -O3 call_typesafe.c -lpthread -lm -o call_typesafe_bin
./call_typesafe_bin
```
