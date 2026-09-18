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
