# Releasing Overtime

This is the maintainer's checklist for publishing Overtime. Everything here is done by the author, by hand or from the repository's Actions tab. The `release` environment, the helper pin and the three secrets the release needs exist, and v1.0.0 is published.

The release itself runs in CI from versioned scripts, so CI and a local dry-run run the same code:

- `scripts/release/release.sh` builds, signs, verifies and packages. `--dry-run` runs every stage with an ad-hoc identity and a throwaway EdDSA key and publishes nothing.
- `scripts/release/publish.sh` publishes. It refuses to run outside the `Release` workflow on a `v*` tag.
- `scripts/release/pin-helper.sh` produces and checks the pinned helper.
- `scripts/release/cut-release.sh` prepares a release on the current checkout: it checks the version, the branch, the tags and the CHANGELOG section, sets the version in `project.yml`, dates the heading, commits "Release X.Y.Z" and makes the annotated tag `vX.Y.Z`. It never pushes. The Cut release workflow (`.github/workflows/cut-release.yml`) runs it, then pushes and starts the release.

## Before the first release: author decisions

Each item has a recommendation. A-1 is done and A-2 is decided; the others are open. Take them in this order, because A-1 rewrites history and the pin records a commit.

### A-1: history privacy (AR-03-05, AR-04-04)

**Done on 2026-10-15.** Before the first push after the public 0.1 source, the unpushed history was rewritten so the first pmset assertion capture (raw assertion identifiers) and the untrimmed network capture were replaced by their cleaned versions in every commit; the tree did not change. Since then every finished change is pushed to `origin/main`. For 1.0.0 the author squashed the whole history into a single commit and deleted the old tag. Pin the helper for a release only from the rewritten history.

### A-2: license

**Decided by the author on 2026-10-15:** MIT with the Commons Clause (`LICENSE`). The licensor is Iván Hernández. Anyone may use, copy and change Overtime, including inside companies, keeping the copyright and license notice; nobody may sell it or charge for a product or service whose value derives entirely or substantially from it. The gates that pin it are `LicenseTerms` in `Packages/OvertimeRuntime/Tests/OvertimeRuntimeTests/SparkleInfoPlistGateTests.swift` (used by `noticeFindings` and `PublicFaceGateTests.licenseFindings`) and their planted controls. The bundle check that `LICENSE` is copied into the app is license-agnostic.

### A-3: secrets custody

Putting the T1 `.p12` and the EdDSA key into GitHub secrets extends ADR 0008's custody to GitHub. The alternative is a local-only release from your Mac. **Recommended:** CI, with the secrets only in the `release` environment, which requires your approval for every run.

### A-4: diagnostics content

The diagnostics archive keeps process names and replaces every slow-driver name. **Recommended:** confirm this before the first public release, as recorded in Phase 3 (03-24, 03-25).

### A-5: repository description and topics

The current description says "with the lid closed" only. Set it, and topics, with `gh repo edit`:

```sh
gh repo edit ivanhernandez-dev/overtime \
  --description "Keeps your Mac awake while Claude Code works, with the lid open or closed. Works with Claude Code. Not affiliated with Anthropic. Apple Silicon and macOS 14+ only." \
  --add-topic macos --add-topic menu-bar-app --add-topic claude-code --add-topic apple-silicon --add-topic sleep
```

The description text, on its own:

Keeps your Mac awake while Claude Code works, with the lid open or closed. Works with Claude Code. Not affiliated with Anthropic. Apple Silicon and macOS 14+ only.

### A-6: the EdDSA key's tested offline backup

With `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` both on, the EdDSA private key is the only way installed copies accept an update at T1 (ADR 0008, implementation note). **Required before v0.1.0:** confirm that the key has an offline backup outside the repository, and that you have restored it once and checked it against the public key `UD7lL+zTuAv5psJB4a94BH94A95GEAlL3iGS26YFV3Q=`.

## One-time setup

1. **The cask.** `Casks/overtime.rb` in this repository is Overtime's Homebrew cask, so the repository is its own tap: `brew tap ivanhernandez-dev/overtime https://github.com/ivanhernandez-dev/overtime`, then `brew install --cask ivanhernandez-dev/overtime/overtime`. Homebrew needs the address because the repository's name does not start with `homebrew-`. As the last step of every release, `publish.sh` commits `Casks/overtime.rb` to `main` of this repository through the contents API, with the message "Update the cask to X.Y.Z" and the release job's own workflow token; it opens no pull request and needs no secret. Keep `main` free of any rule that token cannot pass (required pull requests, required status checks, signed commits), or every release fails at its last step, with the release published and the cask still on the previous version. The cask is always `packaging/homebrew/overtime.rb.template` rendered for one published version, and `ReleaseSourceGateTests` fails when the two disagree: when you change the template, change `Casks/overtime.rb` the same way in the same commit, keeping its version and `sha256`.
2. **The `release` environment** in this repository. **Done on 2026-10-15:** you are the required reviewer (self-review allowed) and a deployment rule allows only `v*` tags. `release.yml` runs only on a `v*` tag, from a tag push or from a dispatch on the tag (Cut release starts it that way), and only behind this environment's approval. The environment's tag rule and the job's own tag check both refuse any other ref.
3. **The three secrets**, in the `release` environment only (never repository-wide):
   - `T1_P12_BASE64`: the T1 certificate and its private key exported as `.p12` (ADR 0008), base64-encoded on one line;
   - `T1_P12_PASSWORD`: the password of that `.p12`;
   - `SPARKLE_ED_PRIVATE_KEY`: the EdDSA private key as one line, the base64 seed;

   You set them yourself, never an agent. `gh secret list --env release --repo ivanhernandez-dev/overtime` lists the names that are set and never a value. It must list exactly `T1_P12_BASE64`, `T1_P12_PASSWORD` and `SPARKLE_ED_PRIVATE_KEY`. To rotate or replace a secret, run its command from your Mac. Each one reads from your offline backup folder or a hidden prompt and prints nothing secret:

   ```sh
   base64 -i <the T1 .p12 in your offline backup folder> | tr -d '\n' | gh secret set T1_P12_BASE64 --env release --repo ivanhernandez-dev/overtime
   gh secret set T1_P12_PASSWORD --env release --repo ivanhernandez-dev/overtime
   tr -d '\n' < <the EdDSA private key file in your offline backup folder> | gh secret set SPARKLE_ED_PRIVATE_KEY --env release --repo ivanhernandez-dev/overtime
   ```

   - `gh secret set T1_P12_PASSWORD` asks for the value with hidden input.
   - `tr -d '\n'` strips the newlines, so the `.p12` secret is one base64 line and the EdDSA secret is the one-line seed.
   - Never pass a secret value as a command argument, because it lands in the shell history and the process list, and never print it. Running a command again replaces the secret, which is also how to rotate it.
4. **Optional:** turn on immutable releases in the repository settings, if GitHub offers it, so a published release's tag and assets cannot change.
5. **Runners.** CI and Release run on GitHub's hosted `xcode-27` image, and Cut release on `macos-26`. Never register a self-hosted runner with the `xcode-27` label: such a machine would pick up the CI jobs on that label, including pull-request code, and the release job with its secrets. The `xcode-27` CI leg runs only for pushes and same-repository pull requests; pull requests from forks get the `macos-26` package tests only.
6. **The Cut release workflow** needs no secret and no setting of its own. It uses the workflow token with `contents: write` and `actions: write`, granted in its own job. Keep `main` free of any rule that token cannot pass (required pull requests, required status checks, signed commits): with such a rule the cut fails at the push and nothing changes on GitHub. On 2026-10-15 `main` has no branch protection and no ruleset.

## Pin the helper

**Done on 2026-10-15:** `Pinned/helper/v1` is committed and `pin-helper.sh --check` reports it current. The steps below are for the next helper version.

The helper is signed once with the T1 identity and shipped byte-identical in every release (ADR 0010). A release refuses to run without a pin for the current `HelperIdentity.version`.

1. After A-1, from a clean checkout of the commit to pin, on your Mac:

   ```sh
   scripts/release/pin-helper.sh --identity 9C54A8E3E576CC8E7EB6D5A2DC63AA7607B821CE --out Pinned/helper/v1
   codesign -d -r- Pinned/helper/v1/OvertimeHelper
   ```

   The second command must print the helper requirement from ADR 0008: `identifier "io.github.ivanhernandez-dev.overtime.helper" and certificate root = H"9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce"`. `pin-helper.sh` refuses to pin while a helper source path has uncommitted changes, because the build copies the working tree but the manifest records the committed ids.
2. Commit `Pinned/helper/v1/OvertimeHelper` and `Pinned/helper/v1/MANIFEST.json` together.
3. From then on, CI runs `pin-helper.sh --check --allow-missing` on every change. A change under the helper's source paths without a version bump fails it with a line naming the path.
4. **Changing helper code** means bumping `HelperIdentity.version` and pinning into `Pinned/helper/v<N+1>`. Every user with unplug protection then approves the helper again once, so batch helper changes.
5. Keep app-only code out of `OvertimeHelperCore`. CI watches all of it, so an app-only edit there forces a helper bump and a re-approval for every helper user. Put app-side code in `OvertimeHelperClient` instead.

## Cut a release

There are two ways to cut a release. Both end in the same Release run, which waits for your approval.

### With the Cut release button

1. Pick the version `X.Y.Z`: each part 0 to 99, no suffix, and not lower than the current `MARKETING_VERSION` in `project.yml`.
2. Write the release notes under an undated `## [X.Y.Z]` heading in `CHANGELOG.md`, then commit and push it on `main`. Run the dry-run locally first if anything in the pipeline changed: `scripts/release/release.sh --dry-run --version X.Y.Z`.
3. Start it: Actions > Cut release > Run workflow, branch `main`, version `X.Y.Z`. From your Mac the same is `gh workflow run cut-release.yml --repo ivanhernandez-dev/overtime --ref main -f version=X.Y.Z`.
4. The cut refuses, before it changes anything, when:
   - the version is not `X.Y.Z` with each part 0 to 99 and no leading zero;
   - it does not run on `main`, or the checkout has uncommitted changes;
   - `project.yml` does not have exactly one `MARKETING_VERSION` line and one `CURRENT_PROJECT_VERSION` line;
   - the version is lower than the current `MARKETING_VERSION`;
   - the tag `vX.Y.Z` already exists, locally or on GitHub, or the tags on GitHub cannot be read;
   - `CHANGELOG.md` has no `## [X.Y.Z]` heading, has more than one, has one that is already dated, or has an empty section under it.

   Otherwise it sets `MARKETING_VERSION` to `X.Y.Z` and `CURRENT_PROJECT_VERSION` to `X*10000 + Y*100 + Z` in `project.yml`, dates the heading with the UTC date of the run, commits "Release X.Y.Z" as github-actions[bot] and makes the annotated tag `vX.Y.Z` on that commit. Then one `git push --atomic` sends `main` and the tag together, so both land or neither does. Last, it starts Release on the tag and CI on `main`.
5. It starts both runs itself because GitHub starts no workflow for a push made with a workflow's own `GITHUB_TOKEN`; it starts one only for a dispatch.
6. Wait until the CI run on the release commit is green, then approve the `release` environment in the Release run and read its log (see "Read the release log").

### By hand

1. Pick the version `X.Y.Z` (each part 0 to 99; no pre-release suffixes).
2. In `project.yml`, set `MARKETING_VERSION` to `X.Y.Z` and `CURRENT_PROJECT_VERSION` to `X*10000 + Y*100 + Z` (0.1.0 is 100, 0.1.1 is 101). `release.sh` refuses before building if either differs from the tag.
3. In `CHANGELOG.md`, add the date to the version's heading, for example `## [0.1.0] - 2026-10-20`. The lines between that heading and the next `## [` heading are the release notes, in the appcast and on GitHub; an empty or missing section fails the package stage.
4. Commit "Release X.Y.Z" on `main`. Run the dry-run locally first if anything in the pipeline changed: `scripts/release/release.sh --dry-run --version X.Y.Z`.
5. Tag `vX.Y.Z` on that commit and push the branch and the tag. A tag you push yourself starts Release on its own. A tag that is not on `main` is refused.
6. Approve the `release` environment in the workflow run.

Steps 2 to 5 can also run locally: `scripts/release/cut-release.sh --version X.Y.Z` makes the same commit and tag on your Mac, with the same checks, and pushes nothing. Then push both together with `git push --atomic origin HEAD:refs/heads/main refs/tags/vX.Y.Z`.

### Read the release log

The release log must show:

- the app's designated requirement equal to ADR 0008's string, and the helper's equal to its own;
- the app's entitlements exactly the two ADR 0006 keys, and no `get-task-allow` on the app, the sentinel or the helper;
- the pinned helper's sha256 and cdhash matching its manifest;
- the Sparkle revision and the tool digests matching `scripts/release/pins.env`;
- every Mach-O arm64-only with a `minos` of 14.0 or lower;
- the feed and enclosure signatures verified against the app's own `SUPublicEDKey`;
- `publish: draft created`, `publish: assets uploaded`, `publish: published as latest`, then `publish: cask updated` (or `publish: cask already current` when `main` already has the same cask).

### If the cut fails

A refusal, or a push rejected because `main` moved since the checkout, changes nothing on GitHub: fix the cause and run the cut again. If the push went through but starting Release failed, the tag exists and the button refuses that version. Start Release yourself with Actions > Release > Run workflow on the tag `vX.Y.Z`, or `gh workflow run release.yml --repo ivanhernandez-dev/overtime --ref vX.Y.Z`. If starting CI failed, start it the same way with `gh workflow run ci.yml --repo ivanhernandez-dev/overtime --ref main`. Never move or re-push a tag that a Release run has built from.

### If publishing fails

`publish.sh` prints `publish: refused: <reason>` when a precondition fails, and `publish: failed: <reason>` when a step fails.

- **Before "published as latest":** the release stays a draft and the cask is untouched. Delete the draft (keep the tag), fix the cause, then re-run the job.
- **After "published as latest":** the release is public and `Casks/overtime.rb` on `main` still has the previous version. Re-running the job does not help, because `gh release create` refuses an existing release. Commit the cask to `main` yourself, with the message "Update the cask to X.Y.Z": `packaging/homebrew/overtime.rb.template` with `{{VERSION}}` replaced by the version and `{{ZIP_SHA256}}` by the zip's checksum from the published `SHA256SUMS`.

## After publishing

1. `curl -sIL https://github.com/ivanhernandez-dev/overtime/releases/latest/download/appcast.xml` ends in `200`. Every shipped build reads its feed from this URL, so a broken redirect strands users; check it before announcing the release.
2. Download every asset into one folder and run `shasum -a 256 -c SHA256SUMS`.
3. Pull `main`, which now has the "Update the cask to X.Y.Z" commit, then run `brew update`, `brew style --cask ivanhernandez-dev/overtime/overtime` and `brew audit --cask ivanhernandez-dev/overtime/overtime` against the published cask.

## Human verification list

These checks need a person and real hardware, and are never faked. Each is on the WINDOWS ledger.

1. Create the `release` environment and its secrets (One-time setup). The environment and the secrets exist since 2026-10-15: confirm with `gh secret list --env release --repo ivanhernandez-dev/overtime` that it lists `T1_P12_BASE64`, `T1_P12_PASSWORD` and `SPARKLE_ED_PRIVATE_KEY` and nothing else.
2. Produce the real helper pin with the T1 identity and commit it (Pin the helper). Done on 2026-10-15.
3. Release v0.1.0 with the Cut release button (or by hand) and read the log as in "Read the release log"; check the assets and the "Update the cask to X.Y.Z" commit on `main`.
4. Install from the DMG and from the zip on macOS 15 or later (blocked once, then Open Anyway) and on macOS 14 (Control-click, Open).
5. `brew tap ivanhernandez-dev/overtime https://github.com/ivanhernandez-dev/overtime`, then `brew install --cask ivanhernandez-dev/overtime/overtime`, on a Mac that has not tapped it: record the exact Tap Trust output, and the Gatekeeper behaviour.
6. Build from source as the README says, on a clean Mac.
7. Update v0.1.0 to v0.1.1 through the `latest/download` redirect with the signed feed. The login item, Notifications, Location and the installed helper all survive, with no re-approval and no App Management prompt; About shows 0.1.1 (101).
8. A scheduled update found while Overtime is not in focus shows the reminder row in the panel and the About badge, and no notification.
9. An update installs while keep-awake holds: the hold resumes after the relaunch, and only one Overtime process runs.
10. In-app uninstall with and without purge; with the helper installed; with `SleepDisabled` set by the helper (cleared through one prompt) and set by you before installing the helper (left alone, with a consent row); and with a failed helper unregister (stops, nothing trashed). Also: with an automatic update staged, uninstall, and check that `Overtime.app` does not reappear in Applications.
11. `scripts/uninstall.sh` with the app present, and again after deleting the app.
12. `brew uninstall --zap --cask overtime`: the helper job is gone, no Login Items row remains, and the purge paths are gone.
13. **The macOS 14 floor run**, on a macOS 14 virtual machine in Tart or on a physical Mac with macOS 14: install the DMG with Control-click, Open; onboarding; a lid-open idle hold while Claude is busy; an update from the previous release; uninstall. Lid, charger and helper behaviour on macOS 14 need a physical Mac. Check Tart's license terms for personal use before using it. Xcode 27 does not run on macOS 14, so only the shipped artifact is tested there.
14. Set the repository description and topics (A-5).

## Before 1.0.0

This is the runbook for the checks only a person on real hardware can make before Overtime becomes 1.0.0. Run the steps in this order, because some of them destroy the conditions of others: Step 1 sets up a clean starting point, Steps 2 and 3 must run without the helper that Step 4 installs, and Steps 4 and 5 end in an uninstall. Nothing here has been run yet, and nothing is marked passed.

Every step is judged by observed sleep or wake, never by registry state ([ADR 0020](adr/0020-verify-by-observed-sleep.md)): the sleep and wake entries of `pmset -g log`, a gap in the clock across a sleep, and the decision log in `~/Library/Logs/Overtime/overtimed.log`. Read `pmset -g`, `pmset -g log` and `pmset -g assertions` only. The one deliberate power-setting change is the prior-value check in Step 4, and you undo it there. Keep ADR 0020's measurement preconditions: run commands from Terminal or over SSH, never from a Claude Code session; quit any other keep-awake tool; never drain the battery to a critical level and never induce a thermal emergency.

A-1 to A-6 come first: they block the first publish, and Step 2 needs a published release. Each step names what it closes: test items of the earlier phases' UAT files (`01-UAT #2` is test 2 of Phase 1) and entries of the WINDOWS ledger (`WINDOWS #12`), both kept in the planning folder on the author's Mac.

### Step 1: a clean starting point

- **Preconditions:** none.
- **Do:** quit every other keep-awake tool. Make sure no Overtime app is running, from Applications or from a build, and that no Overtime login item is registered (System Settings > General > Login Items & Extensions lists none). Make sure `~/Library/Application Support/Overtime/preferences.json` does not exist, so that the first launch in Step 2 is a first run; Debug builds keep theirs under `Overtime Dev` and do not count. Read `pmset -g | grep SleepDisabled` and write the value down: Step 2 needs it as found, and every hold check from Step 2's self-test on needs it at 0.
- **Expect:** each of these holds.
- **Judged by:** System Settings, the file system and `pmset -g`. No sleep is judged here.
- **Closes:** 01-UAT #1.

### Step 2: install the first release and run without the helper

- **Preconditions:** Step 1 passed. A-1 to A-6 are done and v0.1.0 is published (human verification list, items 1 to 3). SleepDisabled reads as you found it in Step 1. Your iPhone hotspot is a known network on this Mac.
- **Do:**
  1. Download v0.1.0's DMG from the release and copy Overtime to Applications. Before the first launch, run `codesign -d --entitlements - /Applications/Overtime.app`, and the same on `Contents/MacOS/overtime-sentinel` and `Contents/MacOS/OvertimeHelper` inside it. Open it: on macOS 15 or later it is blocked once, then System Settings > Privacy & Security > Open Anyway; on macOS 14, Control-click, Open (human verification list, item 4).
  2. Onboarding opens by itself on this first launch, with seven steps. If SleepDisabled read 1 in Step 1, its "Recommended macOS settings" step shows the system sleep row: choose "Turn Sleep Back On…" and check the administrator prompt's Cancel and quit cases as 02-UAT #3 describes, then accept it. Finish onboarding and set Settings > Network to Auto-detect.
  3. `pmset -g` must read SleepDisabled 0. With the lid open and Claude idle, open Settings > Diagnostics > Setup > Run Onboarding Again and let its last step run the self-test. Then close the lid with Claude busy and read the Network row in the cases of 04-UAT #23 (Wi-Fi off, a wired connection, no iPhone among the known networks, the choice set to None).
  4. Read `~/Library/Logs/Overtime/overtimed.log` and `~/Library/Logs/Overtime/overtimed-error.log`.
  5. Use Overtime for a full day of normal work without installing unplug protection.
- **Expect:**
  - The app carries only the `disable-library-validation` and `personal-information.location` entitlements; the sentinel and the helper carry none; nothing carries `get-task-allow`.
  - Onboarding opened by itself once, on the first launch, with seven steps, and "Launch at login" is on afterwards.
  - Each lid close with Claude busy logs one `NET armed` line when a hotspot is available, or one `NET off` line whose reason is `noHotspot`, `noWifi`, `wired` or `wifiOff`.
  - The self-test row in Settings > Diagnostics reads Passed with the macOS build.
  - The log holds one `CHECK wifi`, one `CHECK hotspot` and one `CHECK screenLock` line, with no Location prompt and no network name.
  - After the day, `ps` shows only your own Overtime and overtime-sentinel processes and no Overtime process running as root, Login Items & Extensions lists no Overtime daemon, and `pmset -g` never shows SleepDisabled changed by Overtime.
- **Undo:** to run this step again, uninstall with purge (Settings > About > "Uninstall Overtime…" with "Also remove settings, state and logs" checked, or `/Applications/Overtime.app/Contents/MacOS/Overtime --uninstall --purge`) and go back to Step 1.
- **Judged by:** `pmset -g` before and after each part; the decision log; `ps -axo user,comm | grep -i overtime`.
- **Closes:** 02-UAT #1, 02-UAT #3, 02-UAT #14, 03-UAT #6, 03-UAT #29, 03-UAT #34, 04-UAT #23, 05-UAT #3 (its install part; the macOS 14 floor run is in Step 5); WINDOWS #14, WINDOWS #15, WINDOWS #22, WINDOWS #34, WINDOWS #63, WINDOWS #89.

### Step 3: lid, battery, kill -9, release, external display and hotspot, without the helper

- **Preconditions:** Step 2 passed. Unplug protection is not installed and SleepDisabled reads 0. Location access is allowed and Settings > Network names a hotspot that is available. A second computer can reach this Mac over SSH and Screen Sharing. An external display and the charger are at hand. "Claude busy" means a Claude Code session working on a long task.
- **Do:**
  1. On battery with Claude busy, close the lid for at least 15 minutes, then wake the display over Screen Sharing and leave it without input.
  2. On battery with the lid open, Claude busy and no input, wait past the display and idle sleep times. Repeat with Settings > General > "Keep display on while Claude works" turned on.
  3. Let Claude finish, once with the lid open on battery and once with the lid closed.
  4. With the lid closed and Claude busy, `kill -9` Overtime from the second computer; repeat four times within 10 minutes. Then plant a relaunch stamp with an out-of-range mtime and kill once more (03-UAT #38).
  5. While holding: Quit from the panel, log out, cancel a logout from another app, and send `kill -TERM` to Overtime.
  6. While holding with the lid closed, choose "Restore Normal Sleep Now"; run `/Applications/Overtime.app/Contents/MacOS/Overtime --reset` with the app running and with it quit. Choose "Sleep Now" while idle and while Claude is busy.
  7. On battery with Claude busy, let the charge fall to Release at (10% by default), then plug in. While holding, change Release at and Resume at, add and remove a transcript folder, and toggle "Keep display on while Claude works".
  8. With the lid closed and Claude busy, unplug the router behind Wi-Fi; read the panel's Network row over Screen Sharing, then open the lid. Also close the lid with Claude busy while the network works, and open it again.
  9. Connect an external display: Claude busy with the lid open, then with the lid closed on the charger.
  10. With the lid open, from Terminal, run `OVERTIME_LIVE_IOKIT=1 swift test --package-path Packages/OvertimeRuntime` once in a source checkout.
- **Expect:**
  1. The Mac stays awake with the display off and the screen locked; after a wake over Screen Sharing the display sleeps again only after 60 s without input.
  2. No idle sleep while Claude works; the display sleeps normally unless "Keep display on" is on.
  3. The hold is released about 180 s after Claude finishes. With the lid open the Mac then idle-sleeps normally; with the lid closed it sleeps, and the log shows `VERIFY sleep ok` within 30 s.
  4. The sentinel clears the clamshell bit first, then relaunches Overtime with `open -g`, and the new instance reclaims or clears the stale hold. The fourth kill inside 600 s logs `relaunch skipped reason=limited`, nothing relaunches, and the Mac sleeps with the lid closed. The out-of-range stamp counts as stale and the sentinel does not crash.
  5. Quit and logout clear first, write the suppression stamp and do not relaunch; a cancelled logout logs `CHECK logout pending` and keeps running; SIGTERM behaves like Quit. Lid-close sleep works after each.
  6. The clamshell bit clears and Overtime's assertions are gone from `pmset -g assertions`; the reason line reads "Normal sleep restored." for 10 s. `--reset` exits 75 with the app running and 0 with it quit. "Sleep Now" sleeps the Mac at once; while Claude is busy the inline confirmation appears and reverts after 5 s; after the wake the hold returns under the normal rules.
  7. The hold is released at 10% and returns on the charger or at 20%. New thresholds, folders and the display setting apply without a relaunch, with one `SETTINGS applied keys=` line naming only keys.
  8. Three offline probes, one `NET join` line and `NET connected` without a cycle; the row reads "On your iPhone hotspot". On lid open, one cycle line, then the Mac on the best known network and `switchedToHotspot` false in `~/Library/Application Support/Overtime/state.json`. With a working network, no `NET join`, `cycleWifi` or `wifiOn` line and no Wi-Fi change.
  9. Overtime never touches the external display.
  10. The live tests pass, none skipped.
- **Judged by:** the sleep and wake entries of `pmset -g log` and clock gaps for every hold and release; `pmset -g assertions`; the decision log and the sentinel's lines in it.
- **Closes:** 01-UAT #3, 01-UAT #4, 01-UAT #5, 01-UAT #6, 02-UAT #9, 02-UAT #10, 02-UAT #12, 02-UAT #13, 03-UAT #30, 03-UAT #38, 04-UAT #2, 04-UAT #6, 04-UAT #7, 04-UAT #8, 04-UAT #9; WINDOWS #1, WINDOWS #2, WINDOWS #3, WINDOWS #5, WINDOWS #9, WINDOWS #10, WINDOWS #19, WINDOWS #20, WINDOWS #23, WINDOWS #25, WINDOWS #64, WINDOWS #67, WINDOWS #71, WINDOWS #72, WINDOWS #73, WINDOWS #74.

### Step 4: the helper

- **Preconditions:** Step 3 passed. SleepDisabled reads 0. The charger and an external display are connected. The second computer can reach the Mac over SSH.
- **Do:**
  1. Read Settings > Unplug Protection before installing, press Install, approve the helper in System Settings > General > Login Items & Extensions, and go through the approval cases of 03-UAT #13 and 03-UAT #14.
  2. With the lid closed and Claude busy, unplug the charger, then disconnect the external display. Then use "Sleep Now", and Apple menu > Sleep with the lid closed.
  3. Engage with the lid closed, then release it by each path in turn: lid open, battery floor, Pause, "Sleep Now", Quit, logout, `kill -9` of the app, a hang (`kill -STOP`), a dropped connection, and "Restore Normal Sleep Now". Read `pmset -g` after each.
  4. "Restore Normal Sleep Now" with the engine wedged and with a helper that does not answer, then `Overtime --reset` as 03-UAT #17 and 03-UAT #33 describe.
  5. Connect to the helper's Mach service from a binary that is not the T1-signed app and call set.
  6. Set SleepDisabled to 1 yourself (`sudo pmset -a disablesleep 1`), engage and release the helper, then set it back to 0 (`sudo pmset -a disablesleep 0`).
  7. Save your work first: a forced restart loses anything unsaved. While the helper holds (SleepDisabled reads 1), force a restart so Overtime cannot release first, by holding the power button. Log in and read `pmset -g`. If it still reads SleepDisabled 1, record the failure, then clear it with `sudo pmset -a disablesleep 0` (the README's recovery command), so the Mac can sleep again.
  8. Make a helper unregister fail with Settings open, as 03-UAT #35 describes.
  9. Uninstall Overtime from Settings > About > "Uninstall Overtime…" with unplug protection installed.
- **Expect:**
  - The Mac does not sleep on either unplug. "Sleep Now" sleeps it and the helper engages again after the wake; a maintenance wake does not engage it. Apple menu > Sleep with the lid closed is blocked while the helper holds (the accepted ADR 0003 and 0009 exception).
  - SleepDisabled reads 1 only while keep-awake is wanted with the lid closed, and 0 after every release path. A `kill -9` or a dropped connection releases at once; a hang releases within 55 to 60 s of the last heartbeat.
  - The foreign client is rejected before any helper method runs, SleepDisabled does not change, and `/Library/Logs/Overtime/helper.log` shows no set.
  - With your own SleepDisabled 1, the helper records that it does not own the value and leaves it at 1 on release.
  - After the forced restart, `pmset -g` reads SleepDisabled 0 and the helper log shows the boot reconciliation.
  - The failed unregister keeps its Error row until Settings is reopened or "Reconnect Helper" is pressed.
  - The uninstall removes the helper: Login Items & Extensions lists no Overtime item and `pmset -g` reads SleepDisabled 0.
- **Judged by:** `pmset -g` after every action; the sleep and wake entries of `pmset -g log`; the helper log; the decision log.
- **Closes:** 03-UAT #8, 03-UAT #9, 03-UAT #10, 03-UAT #11, 03-UAT #12, 03-UAT #13, 03-UAT #14, 03-UAT #16, 03-UAT #17, 03-UAT #31, 03-UAT #33, 03-UAT #35; WINDOWS #39, WINDOWS #40, WINDOWS #42, WINDOWS #43, WINDOWS #44, WINDOWS #45, WINDOWS #46, WINDOWS #48, WINDOWS #49, WINDOWS #65, and the helper case of WINDOWS #94.

### Step 5: a Sparkle update from the previous release, and a clean uninstall

- **Preconditions:** Step 4 passed. The helper pin exists (human verification list, item 2). A release newer than v0.1.0 is published, for example v0.1.1. v0.1.0 is installed again from its DMG, with the login item on, Notifications and Location allowed, and unplug protection installed. A Mac with macOS 14 is at hand for the floor run.
- **Do:**
  1. Leave Overtime out of focus until a scheduled check finds the update (item 8 of the human verification list), then install it from Sparkle's window while keep-awake holds (items 7 and 9).
  2. The in-app uninstall in every case of item 10, including a staged automatic update, and `/Applications/Overtime.app/Contents/MacOS/Overtime --uninstall` with and without `--purge`.
  3. `brew tap ivanhernandez-dev/overtime https://github.com/ivanhernandez-dev/overtime` and `brew install --cask ivanhernandez-dev/overtime/overtime` on a Mac that has not tapped it, then `brew uninstall --zap --cask overtime` (items 5 and 12), and `scripts/uninstall.sh` with the app present and after deleting it (item 11).
  4. The macOS 14 floor run (item 13).
- **Expect:** each result that items 5 and 7 to 13 of the human verification list state. In short: the signed feed is accepted; the login item, Notifications, Location and the helper survive the update with no re-approval and no App Management prompt; About shows the new version; the hold resumes after the relaunch and one Overtime process runs; the reminder shows in the panel and on About, with no notification. Each uninstall leaves no helper job, no purge path and no `Overtime.app` brought back by a staged update; record whether the Login Items row survives the paths where the app is already gone.
- **Judged by:** About; `ps`; `pmset -g`; System Settings > General > Login Items & Extensions; a listing of the purge paths; the decision log.
- **Closes:** 05-UAT #1, 05-UAT #4, 05-UAT #6, 05-UAT #7, 05-UAT #8, 05-UAT #9, 05-UAT #15; WINDOWS #87, WINDOWS #90, WINDOWS #92, WINDOWS #94, WINDOWS #95, WINDOWS #96, WINDOWS #102.

### Step 6: a week of daily use on the installed Release build

- **Preconditions:** Step 5 passed. Overtime is installed in Applications from a published release: the T1-signed Release build, never a Debug or ad-hoc source build, because APP-13 is about the shipped bundle. The sampler records only the processes of `/Applications/Overtime.app`: a Debug build is also named `Overtime.app`, but it runs from DerivedData and is never counted. Unplug protection is installed if you normally use it. The scripts run in a Terminal window you leave open, never in a Claude Code session.
- **Do:**
  1. A one-hour sample first, to prove the tools on this Mac: `scripts/energy/sample.sh --out "$HOME/overtime-energy-hour.csv" --duration 3600`, then `scripts/energy/report.sh --min-span-hours 1 "$HOME/overtime-energy-hour.csv"`. The sampler refuses a file that already holds a record, so to run the hour again, move the earlier hour file aside first.
  2. The week, into a new file: `scripts/energy/sample.sh --out "$HOME/overtime-energy-week.csv" --duration 604800`, through a normal week with its sleeps (the default interval is 60 s). The sampler refuses a file that already holds a record, so for a new attempt move the old file aside or name a new one. A restart, a logout or a closed Terminal window stops the sampler: after each one, start it again on the same file with `scripts/energy/sample.sh --out "$HOME/overtime-energy-week.csv" --duration 604800 --append`. Once the record spans the week, run `scripts/energy/report.sh "$HOME/overtime-energy-week.csv"`, then stop a sampler that is still running with Control-C.
  3. While the helper runs, take its footprint by hand, because it needs root: find its pid with `pgrep -f Overtime.app/Contents/MacOS/OvertimeHelper`, try `top -l 1 -pid <pid> -stats pid,mem` first, and use `sudo footprint <pid>` if `top` cannot read it. Watch its idle wakeups for an hour while idle and while engaged with `top -pid <pid> -stats pid,command,idlew`.
  4. Optionally, one cross-check: `sudo powermetrics --samplers tasks -i 60000 -n 1`.
  5. Fill the four result rows of the implementation note in [ADR 0019](adr/0019-detection-loop-energy-design.md).
- **Expect:** the week's report exits 0 and prints `verdict: PASS`: total CPU of the app, the sentinel and the helper under 0.1% averaged over the awake time in which the app itself was counted (time in which only the helper or the sentinel ran is left out), and the app plus sentinel `phys_footprint` under 40,000,000 bytes. The record must span at least 168 hours (the `--min-span-hours` default) with no gap over 12 hours in which no sampler was running, and the app must be counted in at least 75% of the sampler's awake time; the report's `span`, `coverage` and `app coverage` lines show these, and a sleep the sampler lived through is not such a gap. Exit 1 is FAIL. Exit 2 is INSUFFICIENT: no awake app interval or no sample with readable app and sentinel footprints (as when Overtime is not running from Applications), a record shorter than the minimum span, a sampler stopped for more than 12 hours, or the app counted in less than 75% of the awake time (as when Overtime was quit or crashed for days). Exit 64 is a usage problem, an unsafe `--out`, or an `--out` that another sampler is still recording (each sampler holds a lock folder next to its file, and a lock left by a sampler that no longer runs is replaced). Exit 70 means the report itself failed before a verdict; read its error line and run it again. The helper's footprint and wakeups stay small.
- **Judged by:** the report's lines and exit status, including the sleep gaps, restarts and malformed rows it excludes and counts; the hand readings.
- **Closes:** 03-UAT #32; WINDOWS #105. A-8 follows this step.

### A-8: the energy week

Step 6. When the week's report reads `verdict: PASS`, fill ADR 0019's result rows and mark APP-13 Complete. Until then APP-13 stays Pending.

### A-9: the live checklist

Steps 2 to 5, with and without the helper, in this order. Record each result in its phase UAT file.

### A-10: cut 1.0.0

After A-8 and A-9, release through "Cut a release": the "Release 1.0.0" commit (`MARKETING_VERSION` 1.0.0, `CURRENT_PROJECT_VERSION` 10000 and a dated `## [1.0.0]` CHANGELOG heading), the `v1.0.0` tag and the release. Then close the milestone.

### A-11: accept the requirement audit

The milestone audit is expected not to pass while the human checks and the energy week are pending: it reports them as gaps. Close each gap by running its step, or accept it in writing.

## Key custody

- The T1 certificate's private key and the EdDSA private key live in your login keychain, with an offline backup outside the repository (ADR 0008). For CI they are also the `release` environment's secrets (A-3).
- **The EdDSA key is the only update path at T1.** Overtime requires a signed feed and verifies every update before extracting it. Sparkle's only fallback for an update without a valid EdDSA signature needs an Apple Team ID, which T1 lacks. If the key is lost, every installed copy stops accepting updates, and every user must reinstall by hand. Never lose it; keep the tested backup from A-6.
- Never pass either key on a command line. The release reads the EdDSA key from `SPARKLE_ED_PRIVATE_KEY` and pipes it to Sparkle's tools with `--ed-key-file -`. Never run Sparkle's `generate_keys`: it writes to the keychain.

## T2

The list of what changes when Overtime moves to an Apple Developer ID is in [ADR 0006](adr/0006-t1-self-signed-distribution.md), "T1 → T2 tracking list" and its implementation note.
