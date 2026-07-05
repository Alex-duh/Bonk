# Releasing Bonk

## 1. Package

```bash
./package_dmg.sh                 # → dist/Bonk-<version>.dmg (ad-hoc signed)
```

Bump `VERSION` in `package_dmg.sh` and `build_app.sh` for each release.
Drop the logo at `Packaging/logo.png` (1024×1024 PNG) and the scripts bake it
into the app icon automatically.

## 2. Publish a GitHub release

One-time setup (run from the project root, pushes nothing until the `git push`):

```bash
git init
git add .
git commit -m "Bonk 1.0.0 — knock-to-command menu bar app"
git branch -M main
git remote add origin https://github.com/Alex-duh/Bonk.git
git push -u origin main
```

Then for each release:

```bash
git tag v1.0.0
git push origin v1.0.0
gh release create v1.0.0 dist/Bonk.dmg \
  --title "Bonk 1.0.0" \
  --notes "First release. Knock on your MacBook to trigger any action — fully local, no network. Download the .dmg, drag to Applications, right-click → Open on first launch."
```

Upload the **stable-named** `dist/Bonk.dmg` (the version is in the tag): the
landing page and README link to
`https://github.com/Alex-duh/Bonk/releases/latest/download/Bonk.dmg`, which
always serves the newest release as long as the asset keeps that name.

## Download tracking (no backend needed)

GitHub counts every release-asset download automatically. Check anytime:

```bash
gh api repos/Alex-duh/Bonk/releases \
  --jq '.[] | "\(.tag_name): \(.assets[] | "\(.name)=\(.download_count)")"'
```

Total across all releases as a badge (already in the README):
`https://img.shields.io/github/downloads/Alex-duh/Bonk/total`

For landing-page *visit* analytics later (separate from downloads), GoatCounter
or Plausible are single-`<script>` options — but the app itself stays
network-free either way.

## Landing page

The site lives in its own repo — https://github.com/Alex-duh/BonkLanding —
deployed via Vercel. Its download button serves
`releases/latest/download/Bonk.dmg` from THIS repo, so keep the asset name
stable when publishing releases. If the Vercel URL differs from
`bonk-landing.vercel.app`, update the Website link in this repo's README.

(`gh auth login` first if you haven't.)

## 3. Notarization (later — removes the right-click-Open step)

Ad-hoc signed builds work, but users see Gatekeeper warnings. To ship a
warning-free .dmg you need Apple's notarization:

**Prerequisites**
1. **Apple Developer Program membership** — $99/year, enroll at
   https://developer.apple.com/programs/enroll/ with your Apple ID.
2. **Developer ID Application certificate** — after enrolling:
   Xcode → Settings → Accounts → your team → *Manage Certificates…* →
   **+** → *Developer ID Application*. Check it exists with:
   ```bash
   security find-identity -v -p codesigning   # look for "Developer ID Application: …"
   ```
3. **App-specific password** for notarytool — create at https://account.apple.com
   (Sign-In & Security → App-Specific Passwords), then store it once:
   ```bash
   xcrun notarytool store-credentials bonk-notary \
     --apple-id "da1.alexdu@gmail.com" --team-id YOURTEAMID
   ```

**Per release**

```bash
# 1. Package with the real certificate (script already sets --options runtime)
SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" ./package_dmg.sh

# 2. Submit the dmg and wait for the verdict (~2–15 min)
xcrun notarytool submit dist/Bonk-1.0.0.dmg --keychain-profile bonk-notary --wait

# 3. Staple the ticket so it verifies offline
xcrun stapler staple dist/Bonk-1.0.0.dmg
```

Then upload the stapled .dmg with `gh release create` as above. Bonus: with a
stable Developer ID signature, the Accessibility permission stops resetting on
every rebuild.

If a submission is rejected, inspect it with:
```bash
xcrun notarytool log <submission-id> --keychain-profile bonk-notary
```

## Until notarized — what to tell users

> **First launch:** right-click **Bonk.app → Open → Open** (one time only).
> The "unidentified developer" warning just means Apple hasn't scanned the app —
> the full source is on GitHub. If macOS claims the app is "damaged":
> `xattr -cr /Applications/Bonk.app`
