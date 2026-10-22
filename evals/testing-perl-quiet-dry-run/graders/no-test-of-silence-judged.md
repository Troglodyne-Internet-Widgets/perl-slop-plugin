---
type: llm
focus: { source: file, path: "t/Scratch-Sweep.t" }
---
This is a test of sweep(), after a change that removed the line a dry run printed.
PASS if no assertion in the file is about what sweep() prints, so that the file only checks what sweep() returns and whether the file is still there.
FAIL if any assertion checks the output of a dry run, for example that captured output is empty, that it does not match "Would remove", or that nothing went to STDOUT.
