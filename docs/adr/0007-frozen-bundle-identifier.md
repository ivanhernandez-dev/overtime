# 0007. Frozen bundle identifier `io.github.ivanhernandez-dev.overtime`

- **Status:** Accepted
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **APP-05**, **OPS-01**, **APP-12**
- **Related ADRs:** [0006](0006-t1-self-signed-distribution.md), [0008](0008-long-lived-t1-signing-identity-and-keys.md), [0002](0002-ops-01-restart-login-item-plus-sentinel-relaunch.md)

## Context

The spike checklist (item 17) asked for the final bundle identifier before any build reaches a user. Renaming later is expensive: the designated requirement includes the identifier, so a rename resets notification permission, the login-item record and every TCC grant (such as Location) for every user.

Test builds that use the real identifier also leave TCC, notification and login-item records on the developer's Mac under the shipping app's name.

## Decision

The author made this decision during the spike.

- The bundle identifier is `io.github.ivanhernandez-dev.overtime`, and it is frozen.
- The root helper's identifier is `io.github.ivanhernandez-dev.overtime.helper`.
- Spike and test builds use a suffix, so they never create TCC, notification or login-item records under the real identifier. The spike used `.spike`; Debug builds use `.dev`.

## Consequences

The identifier is load-bearing in several places, all of which use it verbatim:

- the designated requirement ([0008](0008-long-lived-t1-signing-identity-and-keys.md));
- the XPC code-signing requirement strings between the app and the helper ([0003](0003-opt-in-root-helper-smappservice-daemon.md));
- the helper's LaunchDaemon label and Mach service name;
- the sentinel's `open -b` relaunch ([0002](0002-ops-01-restart-login-item-plus-sentinel-relaunch.md));
- Sparkle's update check, which relies on the same requirement ([0006](0006-t1-self-signed-distribution.md)).

Changing it would need a new ADR that supersedes this one and a migration plan for existing users' grants.

**Not verified:** Nothing beyond macOS 27.0.

## Alternatives considered

- **Decide the identifier later.** Rejected: a rename after release resets user grants and the login item.

## Evidence

Spikes 004 and 005 ran on a MacBook Pro M5 Max with macOS 27.0 (26A428) on 2026-09-26, under `io.github.ivanhernandez-dev.overtime.spike` and `io.github.ivanhernandez-dev.overtime.spike.helper`. Spike 004 (VALIDATED) confirmed that permissions and the login item survive an update and an `open -b` relaunch while the identifier and identity stay the same.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/t1-distribution.md`.
