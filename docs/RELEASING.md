# Releasing

Normal flow is unchanged: `./scripts/release.sh vX.Y.Z notes.md --publish`
(see the script header for setup). The Sparkle auto-update chain adds the
steps below.

## Every release

After `--publish` finishes, commit and push `docs/appcast.xml` together with
the `project.yml` version bump. In-app updates go live only when GitHub Pages
serves the new appcast; until then installed apps simply keep waiting (they
never break, they just see no update).

## First Sparkle release only (delete this section afterwards)

Add `auto_updates true` to `Casks/crisp.rb` in `didriksg/homebrew-tap`. The
release script only bumps `version` and `sha256`; the stanza is a one-time
manual edit. It tells `brew upgrade` the app updates itself, and since
Homebrew 6 brew reconciles against the on-disk version instead of
reinstalling.

## The signing key

Updates are EdDSA-signed. The private key lives in the maintainer's login
Keychain (created once with `./vendor/Sparkle/bin/generate_keys`); the public
half is pinned in `scripts/release.sh` as `SUPublicEDKey`. A backup of the
private key is stored in Bitwarden.

- Lost key: no future updates can be signed. Restore from Bitwarden with
  `generate_keys -f <file>`.
- Leaked key: treat like a leaked Developer ID key; an attacker who also
  gains GitHub access could ship signed updates. Rotation is painful (old
  installs pin the old public key), so custody beats rotation.
- Never commit or log the private key. `generate_appcast`/`sign_update` read
  it from the Keychain automatically at publish time.

## Testing an update locally (no publish)

Build the "old" and "new" versions with two dry runs, serve a signed feed
from localhost, and let the old build update itself:

1. `./scripts/release.sh v9.9.8`, copy `build/Crisp.app` somewhere writable,
   point its `SUFeedURL` at `http://localhost:8765/appcast.xml` with
   PlistBuddy and re-sign ad hoc.
2. `./scripts/release.sh v9.9.9`, put `Crisp.dmg` in a feed dir, run
   `./vendor/Sparkle/bin/generate_appcast --download-url-prefix
   http://localhost:8765/ -o <feeddir>/appcast.xml <feeddir>`, then
   `python3 -m http.server 8765` in the feed dir.
3. Quit the installed Crisp first (single-instance lock), launch the test
   copy, and use the panel's Update row. Delete the `SU*` keys from
   `defaults read com.crisp.app` afterwards.
