---
name: cost-control
description: Toggle the cost-control guardrails (spawn guard, usage-budget bands, throttle nudges, version-check messages) on or off, or show their status. Manual switch — never auto-invoked.
argument-hint: "[on|off|status]"
disable-model-invocation: true
allowed-tools: Bash(~/.claude/cost-control/cost-control.sh *)
---

# /cost-control — master switch for the cost-control bundle

The user wants to toggle or inspect the cost-control guardrails. Run exactly:

```
~/.claude/cost-control/cost-control.sh $ARGUMENTS
```

(with no arguments, run `status`). Then relay the script's output to the user
concisely — do not paraphrase away the numbers.

Semantics, so you can answer follow-up questions accurately:

- **off** — writes `~/.claude/cost-control/.disabled`. From the next tool call,
  the spawn guard, the usage-budget guard, the throttle nudge, and the
  version-check message all no-op (they check the flag first and exit 0). No
  restart needed. The statusline keeps rendering (with a dim `[cc-off]` marker)
  and the passive agent-event log keeps writing — neither restricts anything or
  injects text into the conversation.
- **on** — removes the flag; everything re-arms on the next tool call.
- **status** — enabled/disabled, current 5h/7d usage from the state file,
  threshold bands, and how many denials the guards have logged.

Not covered by this switch: the OS-level managed-settings `availableModels`
gate (if the user installed it) — that requires `sudo rm` of the managed
settings file; and the standalone `watchdog-usage.sh` poller, which the user
runs in their own terminal (Ctrl-C stops it). Mention these only if the user
asks why something is still blocked after `/cost-control off`.
