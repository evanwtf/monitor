# Developer ID runbook

How to take a Mac app from "macOS says it is damaged" to "it opens", once, from
nothing. Written while doing it for `monitor`, so the stumbling blocks at the
bottom are the ones that actually cost time rather than the ones a tutorial
imagines.

Nothing here is specific to this app. Substitute your own bundle id, team id and
item names and it works for the next one. `signing.md` is the shorter document:
what this repository does with the result.

## What the words mean

Three things happen, in order, and they are often confused with each other:

1. **Signing** attaches your identity to the bundle. It says who built it.
2. **Notarization** sends the signed bundle to Apple, which scans it and issues
   a ticket. It says Apple has looked at it.
3. **Stapling** writes that ticket into the bundle, so the check works offline.

Skip the third and the app still passes — by asking Apple at every first launch,
on a machine that may have no network. Skip the second and Gatekeeper refuses.

## The certificate you need

| Certificate | Lane |
|---|---|
| Apple Development | building and running on your own machines |
| Apple Distribution | Mac App Store, TestFlight |
| **Developer ID Application** | **an app people download and run themselves** |

Only the third works for a direct download. This is the first place to lose an
hour: the Certificates page shows Distribution certificates that look plausible
and are valid for something else entirely.

**No App ID is required.** A Developer ID app is distributed outside the store,
so the bundle id needs nothing registered on the Identifiers page.

Only the **Account Holder** can create one.

## The procedure

### 1. Decide which Mac holds the private key

Whichever Mac generates the key ends up holding it. If a build server does the
signing, generating there is one less transfer. Generating on a laptop is fine
too — the key moves as a `.p12`.

### 2. Generate a key and a certificate request

Keychain Access → Certificate Assistant → *Request a Certificate From a
Certificate Authority*, saved to disk, is the path Apple documents. It puts the
key straight into the keychain where `codesign` looks for it.

`openssl` works as well and is easier to script:

```sh
openssl req -new -newkey rsa:2048 -nodes \
    -keyout devid.key -out devid.csr \
    -subj "/emailAddress=you@example.com/CN=Your Name/C=US"
```

The key is a loose PEM this way, so it has to be imported deliberately later.

### 3. Ask Apple for the certificate

developer.apple.com → Certificates, Identifiers & Profiles → Certificates →
**+** → **Developer ID Application**. Upload the `.csr`, download the `.cer`.

### 4. Check that the certificate matches the key

Do this before anything depends on it. Comparing the public halves is cheap and
prints no secret:

```sh
openssl x509 -inform DER -in developerID_application.cer -pubkey -noout \
    | openssl md5
openssl pkey -in devid.key -pubout | openssl md5
```

Two identical hashes mean the pair is right. Different ones mean the `.cer`
answers a different request, and everything after this would fail with an error
about the key being unavailable.

### 5. Import the identity

From a `.p12`:

```sh
security import identity.p12 -k login.keychain-db -T /usr/bin/codesign
```

From a loose key and certificate, which import separately:

```sh
security import developerID_application.cer -k login.keychain-db
security import devid.key -k login.keychain-db -T /usr/bin/codesign
```

Confirm — this is the string you will refer to everywhere afterwards:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 6. Make a `.p12` and back it up

The `.p12` is the certificate and its key together, and it is the only way to
move the identity to another Mac. **Losing the key means revoking the
certificate and starting again**, so back it up before relying on it.

```sh
openssl x509 -inform DER -in developerID_application.cer -out devid.pem
export PW="$(op read 'op://<vault>/<item>/password')"
openssl pkcs12 -export -legacy -inkey devid.key -in devid.pem \
    -name "Developer ID Application: NAME (TEAMID)" \
    -out identity.p12 -passout env:PW
unset PW
```

Store the `.p12` **and its password on the same 1Password item**, so restoring
is one lookup rather than two that can drift apart.

Keychain Access → My Certificates → right-click the identity → Export produces
the same thing with the certificate chain included, if the clicking is
preferable.

### 7. Register notarization credentials

`notarytool` needs an **app-specific** password from appleid.apple.com, not the
Apple ID password. Store it in a named keychain profile:

```sh
xcrun notarytool store-credentials <profile> \
    --apple-id you@example.com --team-id TEAMID --password <app-specific>
```

Keep the app-specific password in 1Password too. The profile cannot be read back
out, so a rebuilt machine means a new password otherwise.

Verify immediately. It costs nothing and the alternative is finding out twenty
minutes into a submission:

```sh
xcrun notarytool history --keychain-profile <profile>
```

"No submission history" with no error is a pass.

### 8. Sign

```sh
codesign --force --deep --options runtime --timestamp \
    --sign "Developer ID Application: NAME (TEAMID)" MyApp.app
codesign --verify --strict --verbose=2 MyApp.app
```

`--options runtime` and `--timestamp` are not optional. The notary service
rejects a bundle without either, and **neither can be added afterwards** — a
missing one means signing again from the start.

### 9. Notarize, staple, and zip again

```sh
ditto -c -k --keepParent MyApp.app MyApp.zip
xcrun notarytool submit MyApp.zip --keychain-profile <profile> --wait
xcrun stapler staple MyApp.app
rm MyApp.zip && ditto -c -k --keepParent MyApp.app MyApp.zip
```

`ditto`, not `zip`: a bundle holds symlinks and extended attributes that `zip`
flattens.

The last line is the step most easily lost. See the stumbling blocks.

### 10. Verify like a downloader

```sh
codesign -dvv MyApp.app                    # Authority=Developer ID Application…
xcrun stapler validate MyApp.app           # The validate action worked!
spctl --assess --type execute -vv MyApp.app
```

`spctl` is the real question. Its two answers:

```
rejected   source=Unnotarized Developer ID   signed, ticket missing
accepted   source=Notarized Developer ID     ready to publish
```

### 11. Automate it

Signing needs the private key, so the job has to run somewhere the key is. On a
self-hosted Mac, keep the credentials in that machine's keychain and pass only
*names* through CI — an identity string and a profile name, neither secret. On a
hosted runner there is no choice but to import a `.p12` from a secret into a
temporary keychain and delete it afterwards.

Make it fail loudly. A release that silently falls back to an ad-hoc signature
publishes a download nobody can open, and the failure surfaces as a bug report
from a stranger a week later.

## Stumbling blocks

Every one of these cost real time.

**Apple Distribution is not Developer ID.** The Certificates page lists
Distribution certificates that are valid, current, and useless for this. Read
the Type column.

**`codesign -dv` prints no `Authority` lines.** Verbosity 1 shows none at all,
so a script that greps for the signing authority always finds nothing. Use
`-dvv`.

**`grep -q` plus `set -o pipefail` is a false failure.** `grep -q` exits on the
first match, which SIGPIPEs the command feeding it, which under `pipefail` fails
the whole pipeline. Checking for a signature this way reports *unsigned* on a
bundle that is signed correctly, which is the worst direction for a check to be
wrong in. Capture the output and test the variable instead.

**Stapling writes to the bundle, not to the archive.** The zip that was uploaded
is still unstapled after `stapler` runs. Publishing it means every download
phones Apple on first launch and fails outright when offline. **Rebuild the zip
after stapling.**

**Hardened runtime and the timestamp cannot be added later.** Notarization
rejects a bundle without them, and the fix is a full re-sign. Put both in the
signing command from the start.

**The Apple ID password does not work with `notarytool`.** It needs an
app-specific password. The error does not make that obvious.

**Notarization is queue time.** A few minutes is typical, twenty happens, and
neither means anything is wrong. `notarytool history` distinguishes *In
Progress* from a real failure. Budget for it in CI: a `--wait` holds the runner
for the duration.

**A `.p12` password must reach `openssl` through the environment.** `PW=…` sets
a shell variable; `-passout env:PW` reads the environment. Without `export` it
fails with "No environment variable PW".

**`op item create --generate-password` only works on Login and Password items.**
So a generated password and a file attachment cannot be created in one command
on an API Credential item. Create the item as a Password and attach the file to
it afterwards.

**`op item create` has no `--password` flag.** The value is an assignment. To
keep it out of shell history, read it into a variable first with `read -rs`.

**A build server may have no login keychain.** A runner installed as a
LaunchDaemon runs without a login session, so `codesign` cannot reach the key
and hangs on a dialog nobody will answer. Run it as a LaunchAgent under a real
user, or give the job a dedicated keychain it unlocks itself. Either way the key
needs its partition list opened for non-interactive use:

```sh
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k <keychain-password> login.keychain-db
```

**`errSecInternalComponent` means the key is unreachable, not missing.** This
is the one that costs an afternoon, because the message names nothing useful
and the identity is right there in `security find-identity`. On a GitHub
self-hosted runner the usual cause is `SessionCreate = true` in the LaunchAgent
plist that `svc.sh` installs: it spawns each job into its own security session,
which does not inherit the unlocked login keychain. Set it to `false`, then
`launchctl bootout` and `bootstrap` the agent. A signing runner also needs
somebody logged in at the console — it cannot be headless.

**An SSH session does not inherit the GUI keychain unlock either.** Setting the
machine up remotely, every `security` and `notarytool` command needs an
explicit `security unlock-keychain` first, even though the same keychain is
unlocked for the user sitting in front of it. That is a property of the setup
session and says nothing about whether the build will work.

**The certificate expires with the membership**, not five years out. This
matters less than it looks: a build signed *and notarized* while the certificate
was valid keeps working afterwards, because the secure timestamp proves when it
was signed. Expiry stops new signing, not old downloads.

## When notarization is rejected

```sh
xcrun notarytool log <submission-id> --keychain-profile <profile>
```

The log names the file and the reason. The common three are a missing hardened
runtime, a missing secure timestamp, and a bundle signed ad-hoc — all of which
are decided back at step 8.
