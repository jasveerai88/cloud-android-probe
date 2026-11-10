#!/usr/bin/env bash
# PhoneVault guest-fetch driver (v4.9) - runs HOST-side, invoked by step 14b of the
# wake workflow after the guest http_proxy readback has MATCHED the pinned endpoint.
# It pushes the checksum-pinned static curl from tools.txt into the guest
# (/data/local/tmp, per-wake tooling) and runs it IN THE GUEST through the pinned
# proxy, so the run can prove the guest's own egress address - the link the toybox
# wget on this image could never prove (no TLS in toybox wget).
#
# v4.9 hardening: run #40's single TLS fetch to api.ipify.org flaked (curl 35
# "Recv failure") while the host probe and the guest readback both passed - one
# endpoint's silence must not decide the verdict. The fetch now rotates: up to
# three independent HTTPS echo endpoints, then ONE plain-HTTP echo as the final
# fallback (which separates a TLS problem from a proxy problem), with a short
# pause between attempts and one printed line per attempt.
#
# Inputs:
#   $1 = adb serial (e.g. emulator-5554)
#   $2 = tools dir (the folder holding tools.txt, relative to the repo root)
#   env PV_GF_ENDPOINT = the pinned endpoint host:port[:user[:pass]] - the exact
#        value the guest readback just matched, so this fetches through the
#        readback-verified setting. NEVER printed by this script.
#   env PV_GF_EXPECTED = the pinned egress IP (may be empty = no expectation set)
#
# Output (stdout): one GUEST FETCH ATTEMPT line per try, then the two lines the
# workflow consumes:
#   GUEST FETCH: egress='<ip or <no answer>>' expected='<ip or <unset>>' - <verdict text>
#   GUESTFETCH_RES=<verdict text>            (the step folds this into its EGRESS: line)
# Contract: EVERY path prints the consumed lines and exits 0 - a failed fetch is a
# printed line only and must never fail the wake. No credential substring is ever
# printed: the proxy argument uses the canonical split form (--proxy host:port +
# --proxy-user), and guest error text is masked before printing (combined
# user:pass, bare user and bare pass forms - the v4.8 stub catch).
set +e
SERIAL="${1:-emulator-5554}"
GT_DIR="${2:-phonevault/guest-tools}"
PEND="${PV_GF_ENDPOINT:-}"
PEXP="${PV_GF_EXPECTED:-}"

gf_done() { # $1 = egress ip or empty, $2 = verdict text
  echo "GUEST FETCH: egress='${1:-<no answer>}' expected='${PEXP:-<unset>}' - $2"
  echo "GUESTFETCH_RES=$2"
  exit 0
}

# --- manifest: first non-comment line, bare filenames only (same rule as apps.txt)
GT_FILE=""; GT_SHA=""; GT_NAME=""
if [ -f "$GT_DIR/tools.txt" ]; then
  while read -r f s n _; do
    case "$f" in ''|'#'*) continue;; esac
    GT_FILE="$f"; GT_SHA="$s"; GT_NAME="$n"; break
  done < "$GT_DIR/tools.txt"
fi
case "$GT_FILE" in */*|'') GT_FILE="";; esac
case "$GT_NAME" in */*|'') GT_NAME="";; esac
if [ -z "$GT_FILE" ] || [ -z "$GT_NAME" ]; then
  gf_done "" "FAILED - guest tool manifest unreadable (no usable line in $GT_DIR/tools.txt)"
fi
if [ ! -f "$GT_DIR/$GT_FILE" ]; then
  gf_done "" "FAILED - guest tool file missing from the checkout ($GT_FILE)"
fi
if [ "$(sha256sum "$GT_DIR/$GT_FILE" | cut -d' ' -f1)" != "$GT_SHA" ]; then
  gf_done "" "FAILED - guest tool sha256 mismatch (refused, never pushed)"
fi
if [ -z "$PEND" ]; then
  gf_done "" "FAILED - no pinned endpoint was handed to the guest-fetch helper"
fi

# --- push + make executable (per-wake: /data/local/tmp does not persist)
adb -s "$SERIAL" push "$GT_DIR/$GT_FILE" "/data/local/tmp/$GT_NAME" >/dev/null 2>&1
adb -s "$SERIAL" shell chmod 755 "/data/local/tmp/$GT_NAME" 2>/dev/null

# --- canonical proxy split (the v4.7 lesson: never one glued host:port:user:pass string)
GU_HOST="${PEND%%:*}"
GU_PORT="$(printf '%s' "$PEND" | cut -sd: -f2)"
GU_USER="$(printf '%s' "$PEND" | cut -sd: -f3)"
GU_CRED="$(printf '%s' "$PEND" | cut -sd: -f3-)"
GU_PASS="$(printf '%s' "$PEND" | cut -sd: -f4-)"

gf_mask() { # $1 = raw guest error text; echoes it with every credential form masked
  local t="$1" s
  for s in "$GU_CRED" "$GU_USER" "$GU_PASS"; do
    if [ -n "$s" ]; then t="${t//"$s"/***}"; fi
  done
  printf '%s' "$t"
}

# --- fetch rotation: 3 HTTPS echo endpoints, then 1 plain-HTTP fallback.
# Any success ends the rotation; the verdict compares against the pinned IP.
GF_URLS="https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com http://api.ipify.org"
GF_IP=""; GF_LASTERR=""; GF_N=0
for GF_URL in $GF_URLS; do
  GF_N=$((GF_N+1))
  if [ "$GF_N" -gt 1 ]; then sleep 3; fi
  GF_CMD="/data/local/tmp/$GT_NAME -sS --max-time 12 --proxy http://$GU_HOST:$GU_PORT"
  if [ -n "$GU_CRED" ]; then GF_CMD="$GF_CMD --proxy-user $GU_CRED"; fi
  GF_CMD="$GF_CMD $GF_URL 2>/data/local/tmp/pv-gf.err"
  GF_TRY="$(adb -s "$SERIAL" shell "$GF_CMD" 2>/dev/null | tr -d '\r\n' | head -c 64)"
  case "$GF_TRY" in *[!0-9.]*|'') GF_TRY="";; esac
  if [ -n "$GF_TRY" ]; then
    echo "GUEST FETCH ATTEMPT $GF_N: $GF_URL -> '$GF_TRY'"
    GF_IP="$GF_TRY"
    break
  fi
  GF_ERR="$(gf_mask "$(adb -s "$SERIAL" shell cat /data/local/tmp/pv-gf.err 2>/dev/null | tail -1 | tr -d '\r')")"
  GF_LASTERR="$GF_ERR"
  if [ -n "$GF_ERR" ]; then
    echo "GUEST FETCH ATTEMPT $GF_N: $GF_URL -> FAILED ($GF_ERR)"
  else
    echo "GUEST FETCH ATTEMPT $GF_N: $GF_URL -> FAILED (no answer)"
  fi
done

if [ -n "$GF_IP" ] && { [ -z "$PEXP" ] || [ "$GF_IP" = "$PEXP" ]; }; then
  gf_done "$GF_IP" "MATCH - the guest itself egressed via the pinned proxy"
elif [ -n "$GF_IP" ]; then
  gf_done "$GF_IP" "MISMATCH - guest egress differs from the pinned address"
elif [ -n "$GF_LASTERR" ]; then
  gf_done "" "FAILED - every echo endpoint failed in the guest; last error: $GF_LASTERR"
else
  gf_done "" "FAILED - guest curl gave no answer on any echo endpoint"
fi
