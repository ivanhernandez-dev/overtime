# 0017. Ignore transcripts whose entrypoint matches `sdk-*` by default

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **DET-03**, **DET-12**
- **Related ADRs:** [0018](0018-caffeinate-before-transcript-ordering.md), [0019](0019-detection-loop-energy-design.md)

## Context

**DET-03** ignores a transcript when the first `"entrypoint"` value in its first 64 KB matches an ignored-entrypoint list, so headless automations do not keep the Mac awake. The original rule filtered only `sdk-cli` (from `claude -p`). Agent SDK automations write other values, such as `sdk-py`, and would count as busy under that rule.

The spike surveyed which entrypoint values actually appear.

## Decision

- The default ignored-entrypoint list for **DET-03** is `sdk-*`.
- The list stays a setting, so a misclassified client can be re-enabled without a release.
- Each entrypoint value that Overtime has not seen before is logged once, so new values get noticed.

## Consequences

- Every non-`cli` entrypoint seen so far is covered by `sdk-*`.
- A new entrypoint, for example from a future desktop app, is logged once and needs a decision on whether it counts. **DET-12**'s detection-health warnings cover broader changes in Claude Code's internals.
- A transcript with no entrypoint still counts as busy (**DET-03**); the survey found none.

**Not verified:** one machine's transcripts only. No `sdk-ts` and no desktop-app entrypoint appeared, so their exact values were not observed.

## Alternatives considered

- **Filter only `sdk-cli`.** Agent SDK automations such as `sdk-py` would keep the Mac awake.

## Evidence

Spike 007 on a MacBook Pro M5 Max running macOS 27.0 (26A428), on 2026-09-26. Verdict: PARTIAL (for reasons unrelated to this survey; see [0016](0016-coexistence-detect-and-warn.md)).

A survey of all 162 transcripts under the default transcript root, subagents included:

| Entrypoint | Transcripts |
|------------|-------------|
| `cli` | 149 |
| `sdk-cli` | 8 |
| `sdk-py` | 5 |

Every file had an entrypoint. No `sdk-ts` and no desktop-app entrypoint appeared.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/coexistence-detection.md`.
