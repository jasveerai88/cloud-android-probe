#!/usr/bin/env bash
# PhoneVault live-link publisher (v5.3 = the v5.2 publisher, re-issued for the v5.3 workflow: per-phone branch/file via PV_LP_BRANCH / PV_LP_FILE env, exported by workflow step 0 - phonevaultverify-live / live-now-verify.txt for PhoneVault Verify; unset = PhoneVault One defaults, byte-identical behaviour) - runs HOST-side, invoked by step 14b of the
# wake workflow when the live window OPENS and again when it CLOSES.
#
# WHY: GitHub renders a job's step Summary only AFTER the job completes, but the
# live window runs mid-job and its endpoint dies before the job ends - so a LIVE
# line left only in the Summary becomes visible exactly when it is useless
# (the owner missed every window this way). This helper publishes the LIVE line
# DURING the window to a dedicated branch, `phonevault-live` (file live-now.txt),
# which Atlas reads raw mid-run, and replaces it with a tombstone when the
# window closes. The end-of-run output commit to main is never touched - the
# publish works in a throwaway temp clone (the run #27 lesson: no racing main).
#
# Usage:
#   live-publish.sh open "<full LIVE line>"
#   live-publish.sh close
# Env:
#   PV_LP_TOKEN      = token with contents:write on this repo (the step passes
#                      the workflow token; NEVER printed by this script, and all
#                      git output is silenced so it cannot leak via error text)
#   GITHUB_REPOSITORY = owner/repo (default Actions env; builds the remote URL)
#   PV_LP_REPO_URL   = full git URL override (used by the stub tests)
# Contract: EVERY path prints one status line and exits 0 - a publish failure is
# a WARNING line only and must never fail the wake. Each call force-resets the
# branch to a single commit holding only live-now.txt; main is never touched.
set +e
LP_MODE="${1:-}"
LP_LINE="${2:-}"
LP_BRANCH="${PV_LP_BRANCH:-phonevault-live}"
LP_FILE="${PV_LP_FILE:-live-now.txt}"

lp_warn() { echo "LIVE PUBLISH: WARNING - $1 - the wake continues"; exit 0; }

if [ "$LP_MODE" = "open" ]; then
  if [ -z "$LP_LINE" ]; then lp_warn "open called without a LIVE line"; fi
  LP_BODY="$LP_LINE"
  LP_MSG="PhoneVault live window open"
elif [ "$LP_MODE" = "close" ]; then
  LP_BODY="window closed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LP_MSG="PhoneVault live window closed"
else
  lp_warn "usage: live-publish.sh open \"<LIVE line>\" | close"
fi

if [ -n "${PV_LP_REPO_URL:-}" ]; then
  LP_URL="$PV_LP_REPO_URL"
elif [ -n "${PV_LP_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  LP_URL="https://x-access-token:${PV_LP_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
else
  lp_warn "no repo URL or token available for the live-branch publish"
fi

LP_TMP="$(mktemp -d 2>/dev/null)" || lp_warn "could not create a temp dir"
trap 'rm -rf "$LP_TMP"' EXIT
cd "$LP_TMP" || lp_warn "could not enter the temp dir"
timeout 60 git init -q . >/dev/null 2>&1
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git remote add origin "$LP_URL" >/dev/null 2>&1
printf '%s\n' "$LP_BODY" > "$LP_FILE"
git add "$LP_FILE" >/dev/null 2>&1
timeout 60 git commit -q -m "$LP_MSG" >/dev/null 2>&1 || lp_warn "git commit failed in the temp clone"
if timeout 90 git push -q -f origin "HEAD:refs/heads/$LP_BRANCH" >/dev/null 2>&1; then
  if [ "$LP_MODE" = "open" ]; then
    echo "LIVE PUBLISH: live link published to branch $LP_BRANCH ($LP_FILE) - readable during the window from that branch's raw $LP_FILE"
  else
    echo "LIVE PUBLISH: tombstone published to branch $LP_BRANCH ($LP_BODY)"
  fi
  exit 0
fi
lp_warn "git push to branch $LP_BRANCH failed"
