# phonevault/apps — the production phone's side-load set

This folder is deployed INTO the repo (jasveerai88/cloud-android-probe) at
the same path, `phonevault/apps/`, alongside the workflow file. From v4.3
the wake step installs this set on every wake (see V43-NOTES.md for why
install-every-wake, not install-once: cross-run persistence of apps is
unproven against the encryption wall, so the set is applied idempotently
and its pre-install presence is measured and logged each wake).

## Format

`apps.txt` — one app per line: `<filename> <sha256> <package>`. The wake
step refuses non-bare filenames, verifies the sha256 before install,
installs with `adb install -r`, and proves presence with
`pm list packages`. Adding an app = drop the APK here + add one line.

## Seeded entry — provenance

- `F-Droid.apk` — the F-Droid client (the app store this Play-Store-less
  google_apis image can bootstrap everything else from).
  - Source: https://f-droid.org/F-Droid.apk (F-Droid's official site,
    the canonical direct-download URL), downloaded 2026-11-10.
  - Size: 12,569,951 bytes. sha256:
    19d51fad482239f6df6a99120e34513667e9a86d136dafdc4a211a68c3327b52
    (computed locally at pin time; the package string org.fdroid.fdroid
    was confirmed inside the APK's binary manifest).
  - Trust model: trust-on-first-download, pinned here. The wake installs
    ONLY bytes matching this hash — a changed upstream file fails the
    check and is skipped, never installed.
  - Size note: 12.6 MB is under GitHub's 25 MB per-file web-upload
    limit, so the normal deploy dance works. A future APK above that
    needs the git CLI or LFS route instead.
