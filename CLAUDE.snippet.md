<!--
  Subagent, workflow & cost-discipline block.
  Paste into ~/.claude/CLAUDE.md (applies to all projects) or a project
  .claude/CLAUDE.md (that project only). Guidance is ~70% adherence — the hooks
  in this bundle are the ~100% backstop. Keep both.
-->

## Subagent & workflow cost discipline

**Two budgets, and they trade against each other.** Context window (per-thread,
~200K) is what compaction and reasoning quality care about. Usage limit (the
5-hour rolling window + weekly caps) is total weighted tokens across *every*
thread, subagent, and parallel branch — one shared bucket. Subagents and
parallelism BUY context-window headroom by SPENDING more usage. They are a
coherence tool, not a savings tool. Never reach for them to "save tokens."

**Model routing (the real lever — the WORK model dominates, not the orchestrator):**

| Model | Use for |
|---|---|
| `haiku` | read-only exploration, search, lookup, log/diff scanning |
| `sonnet` | **default** — general work, code edits, tool/script execution, multi-step |
| `opus` | orchestration/lead, or critical adversarial review only |
| `fable` | never for a subagent; reserve for a lead session you're actively watching |

Invariants: a subagent's model must be **≤ the main-chat model**; **never spawn a
subagent on `fable`**; set an explicit **`effort`** too (`low`/`medium` for
mechanical work, `high` only for hard reasoning).

**Never inherit the model implicitly.** `CLAUDE_CODE_SUBAGENT_MODEL` is a
highest-precedence *override*, not a soft default (docs/en/model-config: it
"overrides the per-invocation `model` parameter and the subagent definition's
`model` frontmatter") — setting it globally steamrolls per-agent frontmatter. So
express defaults through **frontmatter** (pin `model:` on every named
`.claude/agents/*.md`; never `inherit`/`fable`) and set an explicit `model` on
every ad-hoc Agent spawn and every workflow `agent(prompt, {model, effort})`
stage. Use the env var only tactically, for a single session, to force ALL
subagents cheap during a heavy run.

**Bound fan-out.** Workflow agents inherit the *session* model unless a stage
overrides it — so keep heavy/workflow sessions on Opus (plan-included), not
Fable (bills credits past the promo allowance). Workflow size defaults to
`medium` (<15) as of v2.1.219, so that needs no action — set
`workflowSizeGuideline: "small"` in `~/.claude/settings.json` when you want it
tighter (that key overrides the `/config` row). Cap concurrent
subagents at 2–3 unless there's a named reason for more — the platform's own
ceiling is `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, default **20**, and it is
**not enforced at all in ultracode sessions**. Nesting defaults to **3 layers**
(`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`; set `1` to disable), and since v2.1.224
there is **no total-per-session spawn cap** at all. Never leave subagent chains
running unattended.

**Serialize when the 5-hour window is tight.** Parallelism doesn't reduce total
tokens — it raises the burn *rate*, which is exactly what trips the rolling
limit. Near the wall, run work sequentially to spread the same cost across
windows. (The usage-budget hook enforces this automatically above ~80%.)

**One thin brain per project.** Keep a long-lived orchestrator lean: it reads,
plans, dispatches, and synthesizes — heavy/verbose work goes to subagents that
return summaries. Persist state to `STATUS.md` (and PKM), not to chat
scrollback; `/compact` or restart the brain from that doc rather than letting it
accumulate.

**Prompt-cache hygiene (a hidden multiplier).** The main conversation gets a
1-hour cache TTL on-plan; each fresh subagent builds its OWN cache cold on a
5-minute TTL, so large fan-out pays repeated cold-cache write premiums. Rules:
don't switch models mid-session, don't edit CLAUDE.md mid-session, and don't
mutate the tool set mid-task — each invalidates the cache from that point down
and forces an expensive uncached rebuild. Prefer a **fork** over a fresh named
subagent when you just need more hands on the same context (a fork reuses the
parent's cache, system prompt, tools, and model).

**How the spawn gate works (verified vs docs 2026-08-09 / v2.1.226; re-verify
after each `claude update`).** A subagent spawn is a `PreToolUse` call on the
**`Agent`** tool (renamed from `Task` in v2.1.63; `Task` still aliases) — that is
the only hook surface that can block a spawn. `SubagentStart` fires on spawn but
cannot block (docs: "Context only … No blocking or decision control").
`TaskCreated` is the task-*list* event, unrelated to spawns. Settings-level
`PreToolUse` hooks **do** fire for tool calls made inside a subagent — hooks.md
now states it outright: "Hooks from settings files, managed policy settings, and
plugins also run inside subagents … tool events such as `PreToolUse` and
`PostToolUse` fire the same configured hooks as in the main conversation", with
`agent_id`/`agent_type` identifying the subagent. The frontmatter-replicated
guard is kept as belt-and-suspenders, and still matters for one case: **plugin**
subagents ignore frontmatter `hooks:` entirely, so only the settings-level gate
covers them. Version-dependent gotchas: `CLAUDE_CODE_SUBAGENT_MODEL=inherit`
equals unset (v2.1.196+); a per-invocation `model` now survives resume (v2.1.211+);
the custom `Explore` agent pins `model: haiku` so the cheap explorer survives any
change to the built-in's default; and since v2.1.218 **project-level** agent
frontmatter hooks require workspace trust for the folder holding the agent file —
user-level agents in `~/.claude/agents/` (where this bundle installs) are exempt.

## Verbosity tiering

- Default: terse. Answer, then stop. No preamble, no closing summary, no
  narration of tool steps.
- Reasoning/debugging: keep the FULL troubleshooting sequence — hypotheses,
  what was tested, why each was accepted/rejected. The step-by-step IS the
  deliverable; do not compress it.
- PKM / ADR / docs: full detail and structure — this content is kept and
  referenced later.
- Routine edits/lookups: one-line confirmation.
- Escalate verbosity by task type, not by default. When usage is high, the
  throttle hook will inject a directive to compress further — honor it, but never
  drop reasoning that correctness depends on.
