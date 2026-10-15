# 0010. Ship the helper binary byte-identical across T1 releases

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-16**, **APP-05**, **APP-07**
- **Related ADRs:** [0003](0003-opt-in-root-helper-smappservice-daemon.md), [0006](0006-t1-self-signed-distribution.md), [0008](0008-long-lived-t1-signing-identity-and-keys.md)

## Context

The helper ([0003](0003-opt-in-root-helper-smappservice-daemon.md)) ships inside the app bundle and is updated with it by Sparkle (**APP-05**). Under T1 signing:

- A **changed** helper binary is killed by launchd at launch: `SIGKILL (Code Signature Invalid)`, namespace `CODESIGNING`, "Launch Constraint Violation". XPC calls to it just hang. Only switching "Allow in the Background" off and on in System Settings refreshed the constraint.
- A **byte-identical** helper (same CDHash) survived a Sparkle update and a crash restart from the new bundle with no re-approval. The launch constraint pins the helper's code identity, not the app bundle.
- Sparkle does not restart the running helper. The old binary keeps serving until it exits.

## Decision

- Under T1 the helper is built and signed **once** as a versioned artifact and copied byte-for-byte into every release until its code must change. It is never re-signed per release ([0006](0006-t1-self-signed-distribution.md)).
- **Version handshake.** On connect, the app reads the helper's version. If it is stale and the binary is unchanged or already re-approved, the app asks the helper to exit, and launchd relaunches the bundled one.
- **Re-approval detection.** The app treats `daemon.status == .enabled` with XPC unreachable, plus a Launch Constraint crash report, as "needs re-approval". It shows "Re-approve the helper" and calls `SMAppService.openSystemSettingsLoginItems()` (**APP-07**).

## Consequences

- Every change to the helper's code forces a re-approval for every user who installed it. Helper changes are batched and kept rare.
- The helper's signing uses the same long-lived identity as the app ([0008](0008-long-lived-t1-signing-identity-and-keys.md)); losing that identity would also force a re-approval.
- The release pipeline needs a stored, signed helper artifact and a check that the shipped copy is byte-identical to it.

**Not verified:**

- The evidence for pinning is one identical-hash update (n=1).
- Under T2 (Developer ID) the launch constraint is expected to key on the Team ID, which would let a changed helper run without re-approval. This is untested, and it is a strong reason to reach T2 before the helper ships widely.
- macOS 14 and 15.

## Alternatives considered

- **Re-sign the helper on every release.** Forces a user re-approval on every release, with XPC hanging until the user acts.
- **Ship the helper only at T2.** Avoids the constraint problem but delays **HOLD-15** protection for all T1 users.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 005, on 2026-09-26. Verdict: PARTIAL.

- A rebuilt helper with changed code was killed at launch with "Launch Constraint Violation" until "Allow in the Background" was toggled off and on.
- A byte-identical helper survived a Sparkle update and a crash restart from the new bundle with no re-approval.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/root-helper.md`.

## Implementation notes (2026-10-10)

Phase 5 built the stored artifact and the check this decision asks for (delegated by the project author). The first real pin is an author step in `docs/RELEASING.md`; no pin exists yet.

- **The rule now: the pin is committed.** The T1-signed helper lives at `Pinned/helper/v<N>/OvertimeHelper`, where `N` is `HelperIdentity.version`. Beside it, `MANIFEST.json` records the helper version, its identifier, sha256 and cdhash, the source commit, the Xcode build, the date, and the git tree or blob id of each of the four helper source paths (`overtime-helper`, `OvertimeHelperCore` and the two launchd plists).
- **The rule now: one script signs it, once.** `scripts/release/pin-helper.sh --identity <SHA-1> --out Pinned/helper/v<N>` builds the Release helper and signs it with the given identity; that is the only place the helper is ever signed. The release copies the pinned file into the app before the inside-out signing and verifies its sha256 and cdhash against the manifest, and in a real release its designated requirement too. A release refuses to run without a current pin.
- **The rule now: CI proves the pin is current.** Every change runs `pin-helper.sh --check --allow-missing`. It compares the ids at HEAD with the manifest and fails, naming the path, when a helper source changed while `HelperIdentity.version` did not. `--allow-missing` lets it pass, saying "no pin yet", only until the first pin is committed.
- **Why.** A committed binary is public anyway, since every release ships it, and committing it keeps CI free of a second secret store and makes the pin reviewable. Tree and blob ids survive a history rewrite, which a commit id would not.
- **What did not change.** The version handshake, the re-approval detection, and the cost: changing helper code means bumping the version and re-pinning, and every helper user approves it once more.

Evidence: `scripts/release/pin-helper.sh`, `scripts/release/lib/pin.sh`, `scripts/release/release.sh`, `scripts/release/lib/verify.sh`, `.github/workflows/ci.yml`; the script tests `scripts/tests/test_pin.sh` and `scripts/tests/test_release_dry_run.sh`; `ReleaseSourceGateTests.theReleasePipelineNeverSignsTheHelper`.
