# 0006. T1 distribution: self-signed, Hardened Runtime with `disable-library-validation`, Sparkle 2.10

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **APP-05**, **APP-06**, **APP-12**
- **Related ADRs:** [0007](0007-frozen-bundle-identifier.md), [0008](0008-long-lived-t1-signing-identity-and-keys.md), [0010](0010-pinned-helper-binary.md)

## Context

v1 ships from GitHub Releases and our own Homebrew tap, signed with a stable self-signed identity ("T1"), not a paid Developer ID. **APP-05** requires Sparkle 2 auto-updates with EdDSA. **APP-06** requires documented Gatekeeper steps for macOS 14 and 15+. **APP-12** fixes the platform: Apple Silicon, macOS 14+.

A self-signed identity has no Team ID. Under Hardened Runtime, library validation refuses to load a framework whose Team ID differs from the app's, so `Sparkle.framework` fails to load and the app dies at launch unless something changes.

## Decision

- **Hardened Runtime stays on at T1**, with two entitlements:
  - `com.apple.security.cs.disable-library-validation`, so Sparkle loads without a Team ID;
  - `com.apple.security.personal-information.location`, needed for the Location permission under Hardened Runtime.
- **Sparkle** comes from SwiftPM at `exactVersion: 2.10.0`.
- **Signing.** Builds are signed ad-hoc, then re-signed from the inside out with the T1 identity ([0008](0008-long-lived-t1-signing-identity-and-keys.md)), never with `--deep`. Order: Sparkle's `Installer.xpc`, `Downloader.xpc` (with its entitlements preserved), `Autoupdate`, `Updater.app`, the framework, every other nested executable with its own identifier (the sentinel, for example), then the app.
- **Packaging.** Zips are made with `ditto`, which preserves the framework symlinks the signature depends on.
- **Appcast.** Generated with `generate_appcast --ed-key-file -`, with the EdDSA private key passed on stdin, never on the command line.
- **Sparkle's command-line tools** are pinned by the GitHub asset digest of the 2.10.0 release tarball. They are ad-hoc signed, so that digest is their only integrity check.
- **The root helper is the exception** to per-release signing: it is signed once and shipped byte-identical ([0010](0010-pinned-helper-binary.md)).

What users see:

- The first open of a downloaded zip is blocked by Gatekeeper once. On macOS 15+, System Settings › Privacy & Security › Open Anyway lets it run. On macOS 14, Control-click › Open works.
- Sparkle updates install without a new Gatekeeper check and without an App Management prompt, and keep every permission.

### T1 → T2 tracking list

When Overtime moves to a Developer ID (T2):

1. Drop `disable-library-validation`.
2. Sign with `--timestamp`.
3. Notarize and staple.
4. Keep the same EdDSA key, so Sparkle updates keep flowing across the identity change.
5. Re-test Hardened Runtime with Sparkle.

## Consequences

- Keeping Hardened Runtime on is closer to T2 and still blocks `DYLD_*` injection and debugger attach. The cost is one entitlement that weakens library validation until T2.
- Permissions (Location, Notifications, the login item) and Sparkle's designated-requirement check depend on the identity staying the same across releases ([0008](0008-long-lived-t1-signing-identity-and-keys.md)) and on the frozen bundle identifier ([0007](0007-frozen-bundle-identifier.md)).
- CI signing needs its own keychain with `set-key-partition-list`, because the first `codesign` with the key otherwise raises an "Always Allow" prompt.

**Not verified:**

- Sparkle following GitHub's `releases/latest/download/appcast.xml` redirect. The spike used a local feed on 127.0.0.1 with `NSAllowsLocalNetworking`. Check with the first real release.
- The Homebrew cask install path (Phase 5).
- macOS 14 and 15.
- Delivery of a notification after an update (the permission read `authorized`, but none was sent from the updated build).
- CI signing.

## Alternatives considered

- **Hardened Runtime off at T1.** Also works. Rejected: keeping it on is closer to T2 and still blocks `DYLD_*` injection and debugger attach.
- **Hardened Runtime without the library-validation exemption.** The app dies at launch because Sparkle cannot load.
- **Ad-hoc signing for any build a user keeps.** The designated requirement becomes a cdhash, so TCC grants, the login-item record and Sparkle's requirement check reset on every build.
- **`generate_appcast -s` or `sign_update -s`.** Deprecated, and the key lands on the command line.
- **Developer ID and notarization now.** Paid signing is out of scope for v1.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 004, on 2026-09-26. Verdict: VALIDATED.

- Gatekeeper blocked the first open of a downloaded, quarantined zip; Open Anyway in Privacy & Security let it run.
- Sparkle 2.10 loaded under Hardened Runtime plus `disable-library-validation` with no Team ID.
- A delta update from 0.0.1 to 0.0.2 of 4.6 KB installed and relaunched in 4 s. There was no Gatekeeper re-check (the quarantine flag was gone; only `com.apple.provenance` remained) and no App Management prompt.
- After the update, Location read `authorizedAlways`, Notifications `authorized`, and the login item `enabled`. The designated requirement was unchanged.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/t1-distribution.md`.

## Implementation notes (2026-10-10)

Phase 5 built the release pipeline this decision describes (delegated by the project author). Four points refine it; the decision itself stands.

- **The rule now: Sparkle's tools come from the SwiftPM artifact.** `generate_appcast` and `sign_update` are taken from the Sparkle 2.10.0 artifact that SwiftPM resolves for the app, not from a second tarball download. SwiftPM verifies that artifact against the checksum in Sparkle's manifest, `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`, which equals GitHub's digest for the asset. `scripts/release/pins.env` records the version, the revision `eef1a539a373c1f1a320624b1130fc5de7b2e100` and both tool digests, and `release.sh` refuses to build when the resolved revision or a tool digest differs.
- **The rule now: Sparkle is thinned before signing.** Sparkle's binaries are universal (`x86_64 arm64`), and APP-12 requires arm64 only. Before the inside-out signing, the release runs `lipo -thin arm64` on Sparkle's five Mach-Os (the framework, `Autoupdate`, `Updater`, `Downloader` and `Installer`). Signing and verification never use a recursive flag; every nested item is signed and verified by its own path.
- **The rule now: the DMG is not code-signed at T1.** A self-signed signature on a disk image adds nothing for Gatekeeper. `SHA256SUMS` and the signed app inside carry the integrity, and the README tells users how to check them.
- **The T1 → T2 list gains three items.** 6. Remove any T1-only exception from the `get-task-allow` check (the check has none today; keep it that way). 7. Sign and notarize the DMG. 8. Re-pin the helper under the Developer ID ([0010](0010-pinned-helper-binary.md)); the pin changes, so every helper user approves it once more.
- **Why.** The SwiftPM artifact is already pinned by a checksum SwiftPM enforces, so a second download would add a second thing to pin without adding integrity. The thinning was found when the floor check (`lipo -archs`) failed on every Sparkle binary.
- **What did not change.** Hardened Runtime with the two entitlements, inside-out signing with the order above, `ditto` for the zip, `--ed-key-file -` for the appcast, and the helper as the one item the pipeline never signs.

Evidence: `scripts/release/release.sh`, `scripts/release/lib/pipeline.sh` (`ot_thin_sparkle`, `ot_sign_inside_out`), `scripts/release/lib/verify.sh`, `scripts/release/pins.env`; the script test `scripts/tests/test_release_dry_run.sh`; `ReleaseSourceGateTests` (no recursive signing flag, the pins against the project and ADR 0008, the helper never signed by the pipeline).
