# Signing and notarization

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
on the team, and it is an interactive, one-time job.

## One-time setup on the Mac runner

Signing and notarizing happen in `package.yml`, on the self-hosted macOS runner.
The credentials live in that machine's keychain rather than in GitHub secrets:
it is a Mac on a desk, not a disposable VM, so there is no reason to put a
private key where it can leak.

**1. Install the certificate.** Export it from your keychain as a `.p12` and
import it on the runner, or create it there in the first place. Confirm:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
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

**3. Store notarization credentials.** An app-specific password from
appleid.apple.com, kept in a named profile:

```sh
xcrun notarytool store-credentials monitor-notary \
    --apple-id you@example.com --team-id <TEAMID> --password <app-specific>
```

Keep the app-specific password in 1Password as well — `monitor-notary-password`
in Code Secrets — because the profile on the runner is not readable back out and
rebuilding that Mac would otherwise mean generating a new one.

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
which is exactly the difference stapling buys.

## When notarization is rejected

`xcrun notarytool log <submission-id> --keychain-profile monitor-notary` prints
the reason. The common ones here would be a missing hardened runtime, a missing
secure timestamp, or a bundle signed ad-hoc — all three of which `make-app.sh`
and `notarize.sh` now refuse to produce.
