# PhoneVault guest-tools — pinned binaries the wake workflow pushes into the guest

Per-wake tooling only. Nothing in this folder is part of the phone's identity:
tools are pushed to `/data/local/tmp` during a wake, used, and gone with the run
(that folder does not persist across wakes). The manifest is `tools.txt`
(same style as `apps/apps.txt`); the workflow verifies each file's sha256
host-side **before** pushing — a mismatch means the tool is refused, never pushed.

## curl-x86_64 — static curl for the guest-fetch proof (added v4.8)

- **What:** a single fully-static `curl` binary (ELF 64-bit x86-64, static-pie,
  stripped — no dynamic loader, no library dependencies, so it runs on the
  Android kernel ABI with no bionic involvement). Pushed as `pv-curl`.
- **Why:** the google_apis image's toybox `wget` has no TLS, so the guest could
  never fetch an HTTPS egress-echo itself — every wake's verdict line carried
  "guest fetch: UNPROVEN". This binary closes that link: `guest-fetch.sh` runs
  it in the guest through the pinned proxy and compares the echoed address
  with the pinned one.
- **Source:** the **stunnel/static-curl** project (the stunnel.org team's
  static-curl builds), release **`8.23.0-1`** — the project's own description
  of that release: a security rebuild of curl 8.23.0 with an updated CA bundle.
  Asset: `curl-linux-x86_64-musl-8.23.0-1.tar.xz` from the project's official
  GitHub releases page (github.com/stunnel/static-curl). The musl build was
  chosen because it is fully static; the binary carries curl's embedded CA
  bundle, so HTTPS verifies inside the guest with no guest CA store involved,
  and with an HTTPS proxy curl sends CONNECT with the hostname, so no guest
  DNS is needed either.
- **Checksum chain (verified three ways on 2026-11-10, pinning day):**
  1. The release page publishes a per-binary SHA256 table; its
     linux / x86_64 / musl row for the `curl` binary reads
     `715f85aae6d9caeca203f7c1f8697b02193c53f8dd6112d54647f0777290f23e`.
  2. The downloaded tarball's own bundled `SHA256SUMS` file lists the same
     value for `curl`.
  3. The sha256 computed locally on the extracted binary is the same value —
     and that is the value pinned in `tools.txt`.
  Tarball sha256 (for re-download checks):
  `2e0c54ba696afd0df1e899e4344fa63d53d73107f9ac08173314d9be85bc76fd`.
- **Size:** 10,836,152 bytes (~10.3 MB) — under GitHub's 25 MB single-file
  web-upload limit, so it deploys through the same browser upload route as the
  rest of the repo.
- **Smoke test at pinning time:** the extracted binary was executed on this
  Linux VM (a static musl build runs there too): `curl 8.23.0
  (x86_64-pc-linux-gnu) libcurl/8.23.0 OpenSSL/4.0.3 … Protocols: … https …`.
  Executing it **inside the Android guest** is proven only by the first live
  v4.8 wake — until then that one link stays UNPROVEN (see V48-NOTES.md).

## guest-fetch.sh — the host-side driver

Not a guest tool: the workflow's step 14b invokes it on the runner. It reads
`tools.txt`, verifies the binary, pushes it, runs the in-guest fetch through
the readback-verified proxy endpoint (canonical split form — never a glued
host:port:user:pass string; the v4.7 lesson), masks any credential substring
out of guest error text, and prints the `GUEST FETCH:` verdict line plus a
`GUESTFETCH_RES=` line the step folds into its `EGRESS:` verdict. Every path
exits 0: a failed fetch is a printed line, never a failed wake.
