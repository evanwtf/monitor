# Signing and notarization

**Setting this up from nothing, here or for another app?**
[developer-id-runbook.md](developer-id-runbook.md) is the procedure, with the
parts that cost time called out. This document is the shorter one: what this
repository does with the result.

A local build is signed ad-hoc and that is correct. An ad-hoc signature keeps
the app's identity stable across rebuilds, so macOS does not forget what it
remembered about it, and costs nothing.

A **downloaded** copy is a different question. macOS quarantines anything a
browser writes to disk, and an ad-hoc bundle fails that check with a dialog
saying the app is damaged — which is not what happened, and is indistinguishable
from what it would say about something that really was. Getting rid of that
needs two things, in order: a Developer ID signature, then a notarization ticket
stapled to the bundle.

Both are **off by default**. Nothing below has to exist for a release to build.

## What the app needs

| Certificate | What it is for |
|---|---|
| Apple Development | building and running on your own machines |
| Apple Distribution | the Mac App Store and TestFlight |
| **Developer ID Application** | **an app people download and run themselves** |

Only the third one satisfies Gatekeeper for a direct download. The first two are
a different distribution lane and will not do, however valid they are.

Create it at [developer.apple.com](https://developer.apple.com/account/resources/certificates)
→ Certificates → **Developer ID Application**. It needs the Account Holder role
on the team, and it is an interactive, one-time job. No App ID has to be
registered: a Developer ID app is distributed outside the store, so
`wtf.evan.monitor` needs nothing declared to Apple.

The certificate expires with the membership rather than five years out, and
that matters less than it looks. A build signed *and notarized* while the
certificate was valid keeps working after it expires, because the secure
timestamp proves when it was signed. Expiry stops new signing, not old
downloads.

## One-time setup on the Mac runner

Signing and notarizing happen in `package.yml`, on the self-hosted macOS runner.
The credentials live in that machine's keychain rather than in GitHub secrets:
it is a Mac on a desk, not a disposable VM, so there is no reason to put a
private key where it can leak.

**1. Install the certificate.** The identity travels as a `.p12` — the
certificate and its private key together. Restore it from 1Password
(`monitor-devid-p12` in Code Secrets, password and file on the same item) and
import it:

```sh
security import monitor-devid.p12 -k login.keychain-db -T /usr/bin/codesign
security find-identity -v -p codesigning | grep "Developer ID Application"
```

If the key was generated with `openssl` rather than Keychain Access it is a
loose PEM, and the two halves import separately just as well:

```sh
security import developerID_application.cer -k login.keychain-db
security import monitor-devid.key -k login.keychain-db -T /usr/bin/codesign
```

**2. Let a non-interactive session use the key.** A login keychain will
otherwise put up a password dialog nobody is there to answer, and `codesign`
hangs until the job times out:

```sh
security unlock-keychain login.keychain-db
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k <keychain-password> login.keychain-db
```

If the runner runs as a LaunchDaemon it has no login keychain at all. Run it as
a LaunchAgent under your user, or give it a dedicated keychain and unlock that
in the job.

**A LaunchAgent is not enough on its own.** GitHub's `svc.sh` writes
`SessionCreate = true` into the runner's plist, which spawns every job into its
own security session. That session does not inherit the login session's
unlocked keychain, so `codesign` finds the identity, fails to reach its private
key, and reports `errSecInternalComponent` — an error that says nothing about
keychains. Turn it off and reload:

```sh
p=~/Library/LaunchAgents/actions.runner.<org>.<runner>.plist
cp "$p" "$p.bak"
/usr/libexec/PlistBuddy -c "Set :SessionCreate false" "$p"
launchctl bootout gui/$(id -u)/actions.runner.<org>.<runner>
launchctl bootstrap gui/$(id -u) "$p"
```

The job then runs in the console user's session and signs against the keychain
unlocked at login. The alternative is to keep the separate session and unlock a
keychain inside the job, which means putting its password in a GitHub secret —
the thing keeping the credentials on the runner was meant to avoid.

This needs somebody logged in at the console on that Mac. A runner that signs
is a runner that is not headless.

**3. Store notarization credentials.** An app-specific password from
appleid.apple.com, kept in a named profile:

```sh
xcrun notarytool store-credentials monitor-notary \
    --apple-id you@example.com --team-id <TEAMID> --password <app-specific>
```

The password is an **app-specific** one from
[appleid.apple.com](https://appleid.apple.com/account/manage), not the Apple ID
password, which `notarytool` refuses. Keep it in 1Password as
`monitor-notary-password` in Code Secrets: the profile on the runner cannot be
read back out, so rebuilding that Mac would otherwise mean generating a new one.

Check it took, which costs nothing and answers a question that is otherwise
twenty minutes away:

```sh
xcrun notarytool history --keychain-profile monitor-notary
```

**4. Turn it on.** Two repository *variables* — not secrets, since both are only
names:

```sh
gh variable set SIGN_IDENTITY --body "Developer ID Application: NAME (TEAMID)"
gh variable set NOTARY_PROFILE --body "monitor-notary"
```

From the next release on, `package.yml` signs and notarizes, and the release
notes drop the right-click-to-open paragraph.

## What the scripts do

`Scripts/make-app.sh` signs with `MONITOR_SIGN_IDENTITY` when it is set, a
Developer ID identity from the keychain when it is not, and ad-hoc when there is
neither. Setting the variable makes signing **required** — the script fails
rather than quietly producing an ad-hoc bundle that will not install anywhere.

It signs with `--options runtime` and a secure timestamp. Neither is optional:
the notary service rejects a bundle without them, and neither can be added
afterwards without signing again.

`Scripts/notarize.sh` submits the zip, waits, staples the ticket to the bundle
and **rebuilds the zip**. That last step is the one that is easy to miss.
`stapler` writes into the bundle, not into the archive, so the zip that was
uploaded is still unstapled: publishing it gives every downloader a round trip
to Apple on first launch, and a plain failure if they are offline. The zip has
to be made again, after stapling, around the stapled bundle.

## Doing it by hand

```sh
Scripts/make-app.sh
ditto -c -k --keepParent .build/monitor.app monitor-1.1.0.zip
MONITOR_NOTARY_PROFILE=monitor-notary \
    Scripts/notarize.sh .build/monitor.app monitor-1.1.0.zip
```

## Checking it worked

```sh
codesign -dv --verbose=4 .build/monitor.app   # Authority=Developer ID Application…
xcrun stapler validate .build/monitor.app     # The validate action worked!
spctl --assess --type execute -vv .build/monitor.app   # accepted, Notarized Developer ID
```

`spctl` is the one that answers the question a downloader is really asking. It
reads the staple rather than calling Apple, so it passes with the network off —
which is exactly the difference stapling buys. Its two verdicts are worth
recognising:

```
rejected   source=Unnotarized Developer ID   signed, ticket missing
accepted   source=Notarized Developer ID     what a release should say
```

Notarization is queue time, not work: expect a few minutes, and do not be
alarmed by twenty. `notarytool history` says whether it is still In Progress.

## When notarization is rejected

`xcrun notarytool log <submission-id> --keychain-profile monitor-notary` prints
the reason. The common ones here would be a missing hardened runtime, a missing
secure timestamp, or a bundle signed ad-hoc — all three of which `make-app.sh`
and `notarize.sh` now refuse to produce.
