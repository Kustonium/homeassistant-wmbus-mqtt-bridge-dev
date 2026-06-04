#!/usr/bin/env bash
# Regenerate the auto-drafted skeleton under the current dev CHANGELOG heading.
#
# Hybrid model: the maintainer still writes the final, externally-reviewable
# release notes by hand. This script only keeps a *skeleton* (one bullet per
# cycle commit, grouped by Conventional Commit type) under the dev heading so
# the promote-to-stable gate never blocks on an empty placeholder and the
# maintainer has a ready starting point to expand.
#
# Safety contract:
#   * Acts ONLY on the top CHANGELOG section, and ONLY while it still carries the
#     PROMOTE-CHANGELOG-REQUIRED marker. Once the maintainer finalises the notes
#     and deletes that marker line, this script leaves the section untouched.
#   * The marker token is preserved, so promote-to-stable stays blocked until a
#     human reviews and removes it.
#   * Previous release sections are never modified.
#   * Output is deterministic, so re-runs with no new commits produce no diff.
#
# Pure file transform: rewrites CHANGELOG.md in place and prints a status line.
# Git add/commit/push is handled by the calling workflow.
set -euo pipefail

CFG="config.yaml"
CL="${CHANGELOG_FILE:-CHANGELOG.md}"

raw_ver="$(sed -nE 's/^version:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "${CFG}" | head -n1)"
core="$(printf '%s' "${raw_ver}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"
if [[ -z "${core}" ]]; then
  echo "changelog-skeleton: cannot read core version from ${CFG} — leaving untouched."
  exit 0
fi
heading="## ${core}-dev"

first_heading="$(grep -m1 '^## ' "${CL}" 2>/dev/null || true)"
if [[ "${first_heading}" != "${heading}" ]]; then
  echo "changelog-skeleton: top heading '${first_heading}' != '${heading}' — leaving untouched."
  exit 0
fi

current_section="$(awk 'NR>1 && /^## / {exit} {print}' "${CL}")"
if ! printf '%s' "${current_section}" | grep -q 'PROMOTE-CHANGELOG-REQUIRED'; then
  echo "changelog-skeleton: top section already finalised (no marker) — leaving untouched."
  exit 0
fi

base="$(git log --format='%H%x09%s' | awk -F'\t' '$2 ~ /^chore: bump dev base to/ {print $1; exit}')"
if [[ -z "${base}" ]]; then
  echo "changelog-skeleton: no 'chore: bump dev base to' commit found — leaving untouched."
  exit 0
fi

fixed=""
added=""
changed=""
other=""
while IFS=$'\t' read -r short subject; do
  [[ -n "${subject}" ]] || continue
  case "${subject}" in
    *"[skip ci]"*) continue ;;
    "ci(dev): bump"*) continue ;;
    "chore: bump dev base"*) continue ;;
  esac
  clean="$(printf '%s' "${subject}" | sed -E 's/^[a-z]+(\([^)]*\))?(!)?:[[:space:]]*//')"
  line="- ${clean} (${short})"
  case "${subject}" in
    fix:*|fix\(*)                                   fixed="${fixed}${line}"$'\n' ;;
    feat:*|feat\(*)                                 added="${added}${line}"$'\n' ;;
    perf:*|perf\(*|refactor:*|refactor\(*)          changed="${changed}${line}"$'\n' ;;
    docs:*|docs\(*|test:*|test\(*|chore:*|chore\(*|ci:*|ci\(*|build:*|build\(*|style:*|style\(*) continue ;;
    *)                                              other="${other}${line}"$'\n' ;;
  esac
done < <(git log --no-merges --format='%h%x09%s' "${base}..HEAD")

if [[ -z "${fixed}${added}${changed}${other}" ]]; then
  echo "changelog-skeleton: no cycle commits to draft yet — leaving placeholder untouched."
  exit 0
fi

emit_section() {
  local title="$1" body="$2"
  if [[ -n "${body}" ]]; then
    printf '\n### %s\n%s' "${title}" "${body}"
  fi
  return 0
}

new_section="$(mktemp)"
rest="$(mktemp)"
trap 'rm -f "${new_section}" "${rest}"' EXIT

{
  printf '%s\n\n' "${heading}"
  printf '%s\n' '<!-- PROMOTE-CHANGELOG-REQUIRED: auto-drafted skeleton below — review, expand into full release notes, and delete this line before promoting. -->'
  emit_section "Added" "${added}"
  emit_section "Changed" "${changed}"
  emit_section "Fixed" "${fixed}"
  emit_section "Other (review)" "${other}"
  printf '\n'
} > "${new_section}"

# Everything from the previous release heading (2nd '## ') onward, preserved verbatim.
awk '/^## / {n++} n>=2 {print}' "${CL}" > "${rest}"

cat "${new_section}" "${rest}" > "${CL}.tmp"
mv "${CL}.tmp" "${CL}"
echo "changelog-skeleton: regenerated skeleton under ${heading}."
