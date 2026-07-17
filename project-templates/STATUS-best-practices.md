# STATUS.md — how to run the "project brain" without context bloat

The problem you hit: a long-lived project chat is great as a control center, but
it accumulates context until it bloats, compacts, and starts losing the thread.
The fix is not a bigger context window — it's moving the project's *state* out of
the chat and into a file the chat reloads on demand. `STATUS.md` is that file.

## The core idea

The chat is a **dispatcher**, not a **datastore**. Everything durable lives in
`STATUS.md`; the chat holds only what it needs for the current step. This makes
the brain restartable: `/compact` or a fresh session, re-read `STATUS.md`, and
you're back — cold-start cost is one file, not a 200K-token scrollback.

Wire it up so it's automatic:

- **SessionStart hook** (or a one-line CLAUDE.md rule) injects `STATUS.md` at the
  top of every session, so the brain always boots with current state.
- **End every working session** by updating three sections: `Now`, `Next`, and
  the `Session handoff` block. 60 seconds; it's what makes the next start cheap.
- When the chat gets heavy mid-session, `/compact` — the on-disk `STATUS.md`
  survives compaction and is re-read, so nothing important is lost.

## STATUS.md vs your PKM — they're different layers, both needed

| | STATUS.md | PKM (Obsidian vault) |
|---|---|---|
| Timescale | this week, this thread | durable, cross-project |
| Volatility | high — rewritten constantly | low — distilled, curated |
| Scope | one project's active work | your whole knowledge graph |
| Audience | the project brain, mid-flight | future-you, any project |
| Lifecycle | graduates *into* PKM, then trimmed | permanent |

They're not redundant. `STATUS.md` is the fast scratch layer where realizations
land *the moment they happen*; PKM is where the durable ones live *after* they've
proven out. The flow is one-directional on a cadence: **capture to STATUS.md in
the moment → graduate to PKM on weekly review → trim STATUS.md.**

## The Decisions & Realizations log — the part notes miss

Your instinct is exactly right: the nuances and corrections that surface *inside a
chat session* — "we tried X, it supposedly doesn't work like we thought" — evaporate
if they only live in the transcript. Structured project notes capture *conclusions*;
they rarely capture the *belief→correction chain*, which is what you actually need
when troubleshooting later.

Rules that keep the log trustworthy:

1. **Append-only.** Never edit an old entry to make it "right." Add a new entry
   that supersedes it and mark the old one `superseded by <date>`. The wrong
   belief is data — it's why you won't re-make the assumption.
2. **Every entry is falsifiable.** `Evidence:` is mandatory: a command output, a
   doc URL with a verified-on date, a PR, a transcript reference. "I think" is not
   an entry; "docs say X, verified 2026-07-14" is.
3. **Tag the type**: `decision` (we chose), `finding` (we learned), `correction`
   (we were wrong), `wow` (surprising, worth remembering).
4. **Re-verification flag.** Anything that depends on fast-moving product behavior
   (model pricing, precedence rules, promo terms) gets
   `Status: needs re-verification` with the date it was last checked. Claude Code
   changes weekly; a 6-week-old "fact" is a hypothesis.
5. **Graduate, then link.** When a realization proves durable, write the atomic
   PKM note and replace the STATUS entry with a one-line `[[slug]]` pointer.

The `CLAUDE_CODE_SUBAGENT_MODEL` saga in the template is the canonical example:
believed default → found override → evidenced by the docs line → impact was a
config change + a hook. That entry, six weeks later, is what stops you from
re-enabling the env var and silently wrecking your model roster again.

## Anti-patterns

- Letting the brain "remember" instead of writing it down — it won't survive
  compaction or a new session.
- A STATUS.md that only grows — if it's over ~2 screens, you're not graduating to
  PKM often enough.
- Editing history to look clean — you're deleting the exact troubleshooting trail
  future-you needs.
- Duplicating PKM content here — link to it (`[[slug]]`), don't copy it.
