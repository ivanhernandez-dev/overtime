# 0008. Long-lived T1 signing identity and key custody

- **Status:** Accepted
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **APP-05**, **APP-06**
- **Related ADRs:** [0006](0006-t1-self-signed-distribution.md), [0007](0007-frozen-bundle-identifier.md), [0003](0003-opt-in-root-helper-smappservice-daemon.md)

## Context

Under T1 ([0006](0006-t1-self-signed-distribution.md)), every user's TCC grants, login-item record and Sparkle update path depend on the app's designated requirement (DR) staying the same. For a self-signed certificate, the DR pins the certificate. A regenerated or renewed certificate is a new identity, and every grant resets at once. Keychain Access creates self-signed certificates with a 1-year default validity.

Sparkle 2 accepts an update if the EdDSA signature is valid **or** the new app satisfies the old app's DR. Losing both keys leaves no update path for anyone.

## Decision

The author made this decision during the spike and created the identity on 2026-09-26.

| Asset | Value |
|-------|-------|
| Certificate | Common name "Overtime T1 Code Signing", RSA-2048, `keyUsage=critical,digitalSignature`, `extendedKeyUsage=critical,codeSigning` |
| Validity | 2026-09-26 to 2046-09-21 |
| Leaf SHA-1 | `9C54A8E3E576CC8E7EB6D5A2DC63AA7607B821CE` |
| Sparkle EdDSA public key | `UD7lL+zTuAv5psJB4a94BH94A95GEAlL3iGS26YFV3Q=` |

The DR the build produced, stable while the certificate is unchanged:

`identifier "io.github.ivanhernandez-dev.overtime" and certificate root = H"9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce"`

The DR says `certificate root`, not `certificate leaf`. For a self-signed certificate the root and the leaf are the same certificate, so this is the same hash as the leaf SHA-1 above.

The certificate stays untrusted (`CSSMERR_TP_NOT_TRUSTED`), and `codesign -s <SHA-1>` still signs with it. No trust step and no sudo are needed.

**Custody:**

- The certificate's private key and the EdDSA private key live in the author's login keychain, with an offline backup outside the repository.
- The password protecting the exported certificate lives only in the keychain.
- Private material is never printed and is passed to tools on stdin, never on the command line.
- Recovery rule: never lose both. If the certificate is lost, Sparkle's EdDSA check still carries updates to a new identity. If the EdDSA key is lost, the unchanged code identity still carries them.

## Consequences

- Phase 5 CI imports the identity into its own keychain with `set-key-partition-list` and fails the build if the built app's DR does not match the string above.
- The first `codesign` with the key on a machine raises the login keychain's "Always Allow" prompt once.
- The XPC requirement strings between the app and the helper pin the same certificate hash ([0003](0003-opt-in-root-helper-smappservice-daemon.md)).
- Moving to T2 changes the DR, so TCC grants reset once at that point, while the same EdDSA key keeps Sparkle updates flowing.
- The leaf SHA-1, the DR and the EdDSA public key are public by construction: they are embedded in every signed build and in the app's `Info.plist`.

**Not verified:** a CI import of the identity; nothing beyond macOS 27.0.

## Alternatives considered

- **A certificate with Keychain Access's 1-year default validity.** Every renewal would be a new identity and reset every user's grants.
- **Keeping the keys only in CI.** Losing them would strand every install; an offline backup is required.

## Evidence

Spike 004 on a MacBook Pro M5 Max running macOS 27.0 (26A428), on 2026-09-26. Verdict: VALIDATED. The spike signed with this identity, installed an update from 0.0.1 to 0.0.2 through Sparkle with an EdDSA-signed appcast, and read the same DR before and after the update, with Location, Notifications and the login item intact.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/t1-distribution.md`.

## Implementation notes (2026-10-10)

Phase 5 turned on Sparkle's signed feed, and that changes the recovery rule above (author decision A-6 in `docs/RELEASING.md`; delegated by the project author, to be confirmed by the author before v0.1.0).

- **The rule now.** At T1 the EdDSA key is the sole update path. The app's `Info.plist` sets `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`, so every feed and every archive must verify against the EdDSA public key before Sparkle extracts it. "Never lose both" becomes "never lose the EdDSA key" until T2.
- **Why.** With verification before extraction, Sparkle's only fallback for an archive without a valid EdDSA signature is a Developer ID signature whose Team ID matches the installed app. A T1 app has no Team ID, so the unchanged designated requirement no longer carries an update on its own. Losing the EdDSA key would strand every installed copy until each user reinstalls by hand.
- **Custody.** The EdDSA private key stays in the author's login keychain with an offline backup outside the repository, and for CI in the `release` environment's `SPARKLE_ED_PRIVATE_KEY` secret. Before v0.1.0 the author confirms that the backup has been restored once and checked against the public key above.
- **What did not change.** The certificate, the designated requirement, the public key and the rule that private material is never printed or passed on a command line. Losing the certificate is still recoverable: the EdDSA key carries updates to a new identity. The signed feed stays because it protects every user against a forged appcast or archive; dropping both keys would bring the fallback back and lose that protection.

Evidence: `SparkleInfoPlistGateTests` pins `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` together, and the public key against this record; `ReleaseSourceGateTests` pins the key in `scripts/release/pins.env` and `project.yml` against this record; the release verifies the feed and enclosure signatures against the app's own `SUPublicEDKey` (`scripts/release/edkey.swift`).
