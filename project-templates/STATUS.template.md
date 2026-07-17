---
project: <name>
updated: <YYYY-MM-DD HH:MM>
owner: <you>
# Working memory for THIS project's active thread. Fast-moving. Committed to the
# repo (or synced to PKM). The orchestrator ("project brain") reads this at the
# start of every session and updates it at the end. Distilled durable knowledge
# graduates to PKM on weekly review; this file stays lean.
---

# <Project> — STATUS

## Now (current focus)
<1–3 lines: what we're actively doing and why. Delete when done.>

## Next (queued, ordered)
- [ ] <next concrete step>
- [ ] <...>

## Blocked / waiting
- <thing> — waiting on <what> (since <date>)

## Open questions
- <question that needs an answer before we can proceed>

---

## Decisions & Realizations log  (APPEND-ONLY — newest at top)

> This is the part your notes miss. Every non-obvious thing you *learn mid-session*
> goes here as a dated entry, especially corrections — the "we thought X, turns
> out Y" moments. Never edit an old entry to "fix" it; append a new one that
> supersedes it and mark the old one. The chain of belief→correction IS the
> value: six weeks later it's why you don't re-make the same wrong assumption.
>
> Entry shape:
>   ### <date> — <one-line title>   [decision | finding | correction | wow]
>   **Believed:** <what we assumed going in>
>   **Found:** <what's actually true>
>   **Evidence:** <cmd output / doc URL / PR / transcript ref — how we know>
>   **Status:** <active | superseded by <date> | needs re-verification>
>   **Impact:** <what changed because of this>

### <date> — Example: CLAUDE_CODE_SUBAGENT_MODEL is an override, not a default   [correction]
**Believed:** Setting `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` globally would be a safe
*default* that per-agent `model:` frontmatter could still override.
**Found:** It's the **highest-precedence override** — it steamrolls frontmatter,
downgrading opus reviewers and upgrading haiku explorers. There is no
settings.json "soft default" knob. Express defaults via frontmatter + explicit
per-spawn model instead; use the env var only tactically per-session.
**Evidence:** code.claude.com/docs/en/model-config ("Overrides the per-invocation
model parameter and the subagent definition's model frontmatter"). Verified
2026-07-14.
**Status:** active.
**Impact:** Removed the global env var; pinned frontmatter on all agents; added
the `guard-subagent-model` PreToolUse hook as the hard backstop.

> ^ Note how the *earlier wrong idea* is preserved, not deleted. If a future
> release changes this behavior, append a new `[correction]` entry that supersedes
> this one — don't overwrite it.

---

## Artifacts & pointers
- Key files/PRs: <links>
- Related PKM notes: `[[slug]]`, `[[slug]]`
- Dashboards / runbooks: <links>

## Session handoff (for /compact or a fresh brain)
<3–5 lines a new session needs to resume cold: where we are, the one thing to do
next, and any landmine to avoid. Rewrite this each session end.>
