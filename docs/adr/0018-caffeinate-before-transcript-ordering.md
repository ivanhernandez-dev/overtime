# 0018. Treat Claude Code's `caffeinate` and transcript writes as unordered

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **DET-01**, **DET-02**, **DET-05**, **DET-06**
- **Related ADRs:** [0017](0017-ignored-entrypoints-sdk-prefix.md), [0019](0019-detection-loop-energy-design.md)

## Context

Busy detection combines two signals:

- **DET-01**: a `caffeinate` process whose parent is a `claude` process with a controlling terminal.
- **DET-02**: a transcript modified within the transcript window.

**DET-05** ignores a `caffeinate` with no transcript written for 30 min (the stuck guard), because Claude Code restarts its `caffeinate` even when idle. **DET-06** holds a 60 s release grace after the last busy signal.

A detector that pairs the two signals could be tempted to assume that the transcript write comes first, and to treat a fresh `caffeinate` with no transcript activity as orphaned at once. The spike measured the real order.

## Decision

- The detector treats Claude Code's `caffeinate` and its transcript writes as **unordered**.
- A fresh `caffeinate` with no transcript activity yet gets a grace of at least 2 s before it can be treated as orphaned.
- No fast path assumes that the transcript write comes first.
- The 30 min stuck guard (**DET-05**) already covers the slow path.

## Consequences

- Claude Code replaces its `caffeinate` every 2 to 3 min mid-turn. **DET-06**'s release grace absorbs that PID rotation.
- A previous turn's `caffeinate` can outlive the turn and end only when the next turn starts, so its end is not a reliable "turn finished" signal.

**Not verified:** the ordering is from one turn start (n=1). Verified on macOS 27.0 only. Claude Code may change this behaviour in any release.

## Alternatives considered

- **Assume the transcript write comes before `caffeinate`.** Contradicted by the measurement: `caffeinate` came first.

## Evidence

Spike 007 on a MacBook Pro M5 Max running macOS 27.0 (26A428), on 2026-09-26, with a watcher polling transcript sizes and `caffeinate` processes every 50 ms. Verdict: PARTIAL (for reasons unrelated to this measurement; see [0016](0016-coexistence-detect-and-warn.md)).

- At a turn start, `caffeinate -i -t 300`, with the `claude` process as its parent, appeared 0.35 s before the transcript write carrying the user's message.
- Mid-turn, Claude Code replaced its `caffeinate` about every 2 to 3 min.
- The previous turn's `caffeinate` ended 209 s after it started, at the next turn, not at its 300 s timeout.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/coexistence-detection.md`.
