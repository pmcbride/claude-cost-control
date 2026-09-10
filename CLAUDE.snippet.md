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
mechanical work, `high` only for hard reasoning). This applies to **agent-team
teammates** too: since v2.1.234 the "Default teammate model" `/config` setting is
gone and an unspecified teammate runs on the **leader's** model — name a model on
every teammate spec.

**Never inherit the model implicitly.** ⚠️ **The precedence FLIPPED in v2.1.251.**
`CLAUDE_CODE_SUBAGENT_MODEL` is now a *default*, not an override — sub-agents.md
resolves (1) per-invocation `model`, (2) frontmatter `model:` (`inherit` selects
the session model), (3) `CLAUDE_CODE_SUBAGENT_MODEL`, (4) the session model, and
states outright: *"Before v2.1.251, `CLAUDE_CODE_SUBAGENT_MODEL` came first in
this order and overrode both the per-invocation parameter and the frontmatter."*
The old steamroll behavior moved to a separate switch, **`CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`**
(v2.1.257+), which ignores every definition's `model:` — including the built-in
Explore and Plan agents — and stops Claude passing a model at all; set alone it
forces every subagent onto the *main conversation's* model (a footgun on an
Opus/Fable lead). Forks and `model: inherit` skills stay on the main model either
way. Practical consequence: setting `CLAUDE_CODE_SUBAGENT_MODEL=haiku` globally
is now **safe and useful** — it is the missing "default cheap, let frontmatter
win" knob this bundle previously said did not exist. Still express the roster
through **frontmatter** (pin `model:` on every named `.claude/agents/*.md`; never
`inherit`/`fable`) and set an explicit `model` on every ad-hoc Agent spawn and
every workflow `agent(prompt, {model, effort})` stage — those now win over the env
var, so they remain the authoritative layer. Reserve `..._FORCE` for a single
heavy session where you want everything cheap regardless of the roster.

**Bound fan-out.** Workflow agents inherit the *session* model unless a stage
overrides it — so keep heavy/workflow sessions on Opus (plan-included), not
Fable (bills credits past the promo allowance). Workflow size defaults to
`medium` (<15) as of v2.1.219, so that needs no action — set
`workflowSizeGuideline: "small"` in `~/.claude/settings.json` when you want it
tighter (that key overrides the `/config` row; since the v2.1.233-era docs a
chosen guideline also lowers the `Large workflow` warning threshold to its own
agent count — `medium` warns at >15 instead of >25). Cap concurrent
subagents at 2–3 unless there's a named reason for more — the platform's own
ceiling is `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, default **20**, and it is
**not enforced at all in ultracode sessions**. Nesting defaults to **3 layers**
(`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`; set `1` to disable), and since v2.1.224
there is **no total-per-session spawn cap** at all. Never leave subagent chains
running unattended.

**Cap effort, not just models (`maxEffortLevel`, new in v2.1.267).** Effort level
is the other spend multiplier, and until now nothing could bound it. The
`maxEffortLevel` settings key caps it *"on every provider, including Bedrock,
Vertex and Foundry"*: `"low"`|`"medium"`|`"high"`|`"xhigh"`|`"max"` (`"max"` = no
cap), default unset. Anything higher runs at the cap instead — `/effort`, the
`/model` picker, `--effort`, `CLAUDE_CODE_EFFORT_LEVEL`, **and a skill's or
subagent's `effort` frontmatter**. Two properties make it a real guardrail rather
than a preference: it is `Any file` scope and **the lowest cap across scopes wins,
so a lower scope cannot raise it**; and *"a cap below `xhigh` makes ultracode
unavailable on the models the cap applies to"* — which is the only documented way
to disarm ultracode, whose fan-out ignores `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`
entirely. Per-model exemptions go in that model's `modelSettings` entry
(`"maxEffortLevel": "max"`), and they replace the top-level key only *within the
same settings source*. Not set by this bundle — decide it per machine.

Note also that `effort:` frontmatter on subagents, skills, and custom commands was
silently **ignored** on models with a pinned default effort (Opus 4.7, Opus 4.8,
Fable 5) until v2.1.267 fixed it. Effort pins written before that build were
no-ops on those models and are only now taking effect.

**Serialize when the 5-hour window is tight.** Parallelism doesn't reduce total
tokens — it raises the burn *rate*, which is exactly what trips the rolling
limit. Near the wall, run work sequentially to spread the same cost across
windows. (The usage-budget hook enforces this automatically above ~80%.) Also
know that since v2.1.234 a session stopped by the usage limit **auto-continues
when the window resets** (`autoContinueAtUsageLimit`, default `true`) — an
over-limit session with queued work resumes burning unattended at reset; set it
`false` in user settings to opt out.

**One thin brain per project.** Keep a long-lived orchestrator lean: it reads,
plans, dispatches, and synthesizes — heavy/verbose work goes to subagents that
return summaries. Persist state to `STATUS.md` (and PKM), not to chat
scrollback; `/compact` or restart the brain from that doc rather than letting it
accumulate.

**Prompt-cache hygiene (a hidden multiplier).** The main conversation gets a
1-hour cache TTL on-plan; each fresh subagent builds its OWN cache cold on a
5-minute TTL, so large fan-out pays repeated cold-cache write premiums. ⚠️ **Two
of the three classic rules were retired by v2.1.267.** What still costs a full
uncached rebuild is **editing CLAUDE.md mid-session**. Switching models with
`/model` no longer re-sends every tool definition, and mid-session MCP/plugin
tool additions no longer rewrite the tool block — on supported models they now
arrive as *deferred* definitions. Treat model-switch and tool-set churn as cheap
on ≥v2.1.267 and stale advice below it. Prefer a **fork** over a fresh named
subagent when you just need more hands on the same context (a fork reuses the
parent's cache, system prompt, tools, and model). Since v2.1.229, workflow
fan-outs stagger same-prefix sibling agents so later siblings read the cached
prompt prefix instead of re-paying it — workflow fan-outs are cheaper than
equivalent hand-rolled parallel spawns. (API-key / cloud-provider setups can pin
the TTLs themselves since v2.1.242: `promptCacheTtl` / `subagentPromptCacheTtl`
settings keys, `"5m"` or `"1h"`; on-plan subscribers keep the managed defaults.
Since v2.1.248 a single agent can pin its own TTL via frontmatter
`experimental: {cacheTtl: "5m"|"1h"}` — read only from subagent files, and `1h`
is ignored while the subscription is on usage credits.) **You no longer have to
guess:** v2.1.251 added a per-session `prompt_cache` object to statusline stdin
and a `Prompt cache (main)` line to `/cost` — hit ratio, misses,
`miss_recache_tokens`, `warm`, `ttl`, `expires_at`, and (v2.1.260+)
`last_miss_cause` / `miss_causes` naming *why* the last miss happened. Check it
before blaming cache hygiene for a spend spike. Related fixes now on this build:
resuming a foreground subagent no longer rewrites its tool list (v2.1.265),
teammates/resumed subagents no longer move SubagentStart context out of the prompt
prefix (v2.1.265), and `/effort` on Fable 5.1 no longer invalidates the cache
(v2.1.260). v2.1.267 closed most of the rest: `/model` switches, mid-session
MCP/plugin tool additions, a forked background worker adding `EnterWorktree`, a
disconnected-MCP or upgraded tool disappearing mid-conversation, resumed sessions
re-rendering tool descriptions or rewriting MCP announcements, a `-p` conversation
resumed interactively, and subagents/sessions started with `--system-prompt` /
`--append-system-prompt` re-rendering their prompt and tool definitions — all now
record once instead of breaking prefix reuse.

**How the spawn gate works (verified vs docs 2026-09-10 / v2.1.267; re-verify
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
**New gating surface (v2.1.251):** `PreModelSwitch` can *block* a model switch
(`hookSpecificOutput.permissionDecision` allow/deny/ask, or top-level
`decision: "block"`; matcher runs against the canonical `to_model`) and
`PostModelSwitch` observes one. That is the missing lever for "don't let this
session drift onto Fable/Opus mid-run" — this bundle does not register it yet.
Caveat from the docs: Claude Code skips `PreModelSwitch` for switches it makes
itself (automatic model fallback, restoring a model on resume), and when it can't
canonicalize the target it runs *every* hook regardless of matcher, so a blocking
hook must check `to_model` from its stdin rather than trust the matcher.

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
