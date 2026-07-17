#!/usr/bin/env python3
"""
parse_transcripts.py — no-OTEL, no-Docker local usage report.

Scans Claude Code session transcripts (~/.claude/projects/**/*.jsonl, including
subagent transcripts) and aggregates token usage + a weighted cost estimate by
session, by model, and by agent. Use this when you want a quick answer to
"what burned my 5-hour window" without standing up the Grafana stack.

CAVEAT (from the docs): the transcript JSONL schema is internal to Claude Code
and CAN change between releases. This parser is defensive — it looks for a
`usage` object wherever it appears and skips anything it doesn't recognize — but
if a release moves fields, adjust `extract_usage()`. For a maintained tool that
tracks these changes, see the community `ccusage` project (npx ccusage).

Pricing is per-1M tokens and is EDITABLE below — update when prices change.
The point isn't a billing-accurate figure; it's a relative "which model/session
dominated" signal, weighted so Opus/Fable output tokens dwarf Haiku input.

Usage:
    python3 parse_transcripts.py                 # last 24h, grouped by model
    python3 parse_transcripts.py --hours 5       # the 5-hour window
    python3 parse_transcripts.py --by session    # group by session
    python3 parse_transcripts.py --by agent      # group by subagent file
    python3 parse_transcripts.py --csv out.csv   # dump per-message rows
"""
from __future__ import annotations
import argparse, csv, json, os, sys, time
from collections import defaultdict
from pathlib import Path

# --- editable price table: (input, output, cache_write, cache_read) per 1M ---
PRICES = {
    "opus":   (5.0, 25.0, 6.25, 0.50),
    "sonnet": (3.0, 15.0, 3.75, 0.30),
    "haiku":  (1.0,  5.0, 1.25, 0.10),
    "fable":  (10.0, 50.0, 12.5, 1.00),
}
DEFAULT = (3.0, 15.0, 3.75, 0.30)  # unknown model -> sonnet-ish


def price_for(model: str):
    m = (model or "").lower()
    for key, p in PRICES.items():
        if key in m:
            return p
    return DEFAULT


def extract_usage(obj):
    """Return (model, in, out, cache_write, cache_read) from a transcript line, or None."""
    # usage may sit at top level or under .message
    usage = obj.get("usage") or (obj.get("message") or {}).get("usage")
    if not isinstance(usage, dict):
        return None
    model = obj.get("model") or (obj.get("message") or {}).get("model") or "unknown"
    return (
        model,
        int(usage.get("input_tokens", 0) or 0),
        int(usage.get("output_tokens", 0) or 0),
        int(usage.get("cache_creation_input_tokens", 0) or 0),
        int(usage.get("cache_read_input_tokens", 0) or 0),
    )


def cost(model, i, o, cw, cr):
    pi, po, pcw, pcr = price_for(model)
    return (i * pi + o * po + cw * pcw + cr * pcr) / 1_000_000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--hours", type=float, default=24.0, help="look-back window")
    ap.add_argument("--by", choices=["model", "session", "agent"], default="model")
    ap.add_argument("--csv", help="write per-message rows to this CSV")
    args = ap.parse_args()

    root = Path(args.root)
    if not root.exists():
        sys.exit(f"No transcripts at {root} (set --root).")

    cutoff = time.time() - args.hours * 3600
    groups = defaultdict(lambda: [0, 0, 0, 0, 0.0])  # in,out,cw,cr,cost
    rows = []
    files = list(root.rglob("*.jsonl"))
    scanned = 0

    for f in files:
        if f.stat().st_mtime < cutoff:
            continue
        session = f.parent.name if f.parent != root else f.stem
        is_agent = "subagents" in f.parts or f.name.startswith("agent-")
        agent = f.stem if is_agent else "(main)"
        try:
            for line in f.open("r", errors="ignore"):
                line = line.strip()
                if not line or '"usage"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                u = extract_usage(obj)
                if not u:
                    continue
                model, i, o, cw, cr = u
                if i == o == cw == cr == 0:
                    continue
                scanned += 1
                c = cost(model, i, o, cw, cr)
                key = {"model": model, "session": session, "agent": f"{session}/{agent}"}[args.by]
                g = groups[key]
                g[0] += i; g[1] += o; g[2] += cw; g[3] += cr; g[4] += c
                if args.csv:
                    rows.append([session, agent, model, i, o, cw, cr, round(c, 4)])
        except OSError:
            continue

    if args.csv and rows:
        with open(args.csv, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["session", "agent", "model", "input", "output", "cache_write", "cache_read", "est_usd"])
            w.writerows(rows)
        print(f"Wrote {len(rows)} rows -> {args.csv}\n")

    print(f"Window: last {args.hours}h   files scanned: "
          f"{sum(1 for f in files if f.stat().st_mtime >= cutoff)}/{len(files)}   "
          f"messages: {scanned}   group-by: {args.by}\n")
    header = f"{'GROUP':<40} {'IN':>12} {'OUT':>12} {'CACHE_RD':>12} {'EST_USD':>10}"
    print(header); print("-" * len(header))
    for key, (i, o, cw, cr, c) in sorted(groups.items(), key=lambda kv: kv[1][4], reverse=True):
        print(f"{key[:40]:<40} {i:>12,} {o:>12,} {cr:>12,} {c:>10.2f}")
    tot = sum(g[4] for g in groups.values())
    print("-" * len(header))
    print(f"{'TOTAL (weighted estimate)':<40} {'':>12} {'':>12} {'':>12} {tot:>10.2f}")
    print("\nNote: est_usd is a RELATIVE weighted signal, not a bill. On a Max plan "
          "this maps to how fast each model/session drains your window.")


if __name__ == "__main__":
    main()
