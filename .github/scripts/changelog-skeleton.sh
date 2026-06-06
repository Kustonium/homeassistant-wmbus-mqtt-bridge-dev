#!/usr/bin/env bash
# Per-build CHANGELOG drafter.
#
# Model: one section per CI build of a dev cycle (## X.Y.Z-dev.NN), holding
# exactly the user-facing commits that landed in THAT build (range:
# previous-per-build heading → HEAD). The "humanise the whole cycle under
# ## X.Y.Z-dev" model produced an unreadable tasiemiec and silently dropped
# everything that followed the maintainer's first humanisation. Per-build
# sections are always accurate, never aggregated, and never edited after
# creation.
#
# Safety contract:
#   * Only PREPENDS a new section to the top of CHANGELOG.md. Never modifies
#     existing sections (cycle release notes for past versions stay intact).
#   * Prints a no-op status line and exits cleanly when there is nothing to add
#     (no new commits since the last per-build heading, or no user-facing commits
#     in this build).
#   * Output is deterministic: re-runs with no new commits produce no diff.
#
# Pure file transform: rewrites CHANGELOG.md in place and prints a status line.
# Git add/commit/push is handled by the calling workflow.
set -euo pipefail

CFG="config.yaml"
CL="${CHANGELOG_FILE:-CHANGELOG.md}"

raw_ver="$(sed -nE 's/^version:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "${CFG}" | head -n1)"
if [[ -z "${raw_ver}" ]]; then
  echo "changelog-skeleton: cannot read version from ${CFG} — leaving untouched."
  exit 0
fi
# Need an X.Y.Z-dev.NN form to draft a per-build section. A bare X.Y.Z-dev
# (start of a cycle, before the first CI bump) is skipped intentionally — the
# next CI build will write its own per-build section.
if [[ ! "${raw_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$ ]]; then
  echo "changelog-skeleton: version '${raw_ver}' is not a per-build form X.Y.Z-dev.NN — leaving untouched."
  exit 0
fi
heading="## ${raw_ver}"

# Idempotency: if the section for this exact build already exists, do nothing.
if grep -qxF "${heading}" "${CL}" 2>/dev/null; then
  echo "changelog-skeleton: section '${heading}' already exists — leaving untouched."
  exit 0
fi

# Promote-prep guard: a bare "## X.Y.Z-dev" top heading (no .NN suffix) means a
# human has consolidated the cycle into a single section in preparation for
# promote-to-stable, which requires exactly that heading (see the stable repo's
# promote.yaml). Fragmenting it back into per-build sections would re-break that
# heading check. Normal dev keeps a "## X.Y.Z-dev.NN" top heading, so this guard
# never fires mid-cycle.
core="$(printf '%s' "${raw_ver}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')"
top_heading="$(grep -m1 '^## ' "${CL}" 2>/dev/null || true)"
if [[ -n "${core}" && "${top_heading}" == "## ${core}-dev" ]]; then
  # Fire ONLY for a real, human-finished consolidation — i.e. the bare section
  # carries no PROMOTE-CHANGELOG-REQUIRED marker. The promote workflow opens a
  # new cycle by inserting a bare "## X.Y.Z-dev" placeholder WITH that marker;
  # that placeholder must NOT suppress per-build drafting, or the new cycle would
  # never get its sections.
  top_section="$(awk 'NR>1 && /^## / {exit} {print}' "${CL}")"
  if ! printf '%s' "${top_section}" | grep -q 'PROMOTE-CHANGELOG-REQUIRED'; then
    echo "changelog-skeleton: top heading '## ${core}-dev' is a consolidated promote-prep section — leaving untouched."
    exit 0
  fi
fi

# Commit range = (most recent per-build heading or any heading at all)..HEAD.
# We map the most recent ## heading line in the file to its commit by searching
# the git log for that exact subject; if not found, fall back to "since the most
# recent ci(dev): bump" (the build that produced the previous section).
prev_heading="$(grep -m1 '^## ' "${CL}" 2>/dev/null || true)"
prev_ver="${prev_heading#"## "}"

# Strategy: find the commit that introduced the previous heading into CHANGELOG
# by matching the bump subject for that version. That is the start of THIS
# build's commit range. NB: keep awk reading the whole stream (no early exit)
# so `git log | awk` does not return 141 (SIGPIPE) under pipefail.
range_base=""
if [[ -n "${prev_ver}" && "${prev_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$ ]]; then
  range_base="$(git log --format='%H%x09%s' \
    | awk -F'\t' -v s="ci(dev): bump version to ${prev_ver} [skip ci]" \
        'found {next} $2 == s {print $1; found=1}')"
fi
if [[ -z "${range_base}" ]]; then
  # No matching previous-build commit — fall back to the most recent bump
  # commit of any version, which is the most natural "since the last build".
  range_base="$(git log --format='%H%x09%s' \
    | awk -F'\t' 'found {next} $2 ~ /^ci\(dev\): bump version to .* \[skip ci\]$/ {print $1; found=1}')"
fi
if [[ -z "${range_base}" ]]; then
  # First build ever in this repo — start from the most recent dev-base bump.
  range_base="$(git log --format='%H%x09%s' \
    | awk -F'\t' 'found {next} $2 ~ /^chore: bump dev base to/ {print $1; found=1}')"
fi
if [[ -z "${range_base}" ]]; then
  echo "changelog-skeleton: no anchor commit found — leaving untouched."
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
  # Drop tooling-scoped commits regardless of type — e.g. fix(ci), feat(build),
  # chore(deps). These are not user-facing, so they must not reach the changelog.
  scope="$(printf '%s' "${subject}" | sed -nE 's/^[a-z]+\(([^)]+)\)!?:.*/\1/p')"
  case "${scope}" in
    ci|build|deps|deps-dev|release|changelog) continue ;;
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
done < <(git log --no-merges --format='%h%x09%s' "${range_base}..HEAD")

if [[ -z "${fixed}${added}${changed}${other}" ]]; then
  echo "changelog-skeleton: no user-facing commits between ${range_base:0:7}..HEAD — skipping build ${raw_ver}."
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
trap 'rm -f "${new_section}"' EXIT

{
  printf '%s\n' "${heading}"
  emit_section "Added" "${added}"
  emit_section "Changed" "${changed}"
  emit_section "Fixed" "${fixed}"
  emit_section "Other (review)" "${other}"
  printf '\n'
} > "${new_section}"

# Prepend the new per-build section above the existing content. Existing
# sections are preserved verbatim — including any humanised cycle release notes.
cat "${new_section}" "${CL}" > "${CL}.tmp"
mv "${CL}.tmp" "${CL}"
echo "changelog-skeleton: prepended ${heading} with $(printf '%s' "${added}${changed}${fixed}${other}" | grep -c '^-' || true) entries."
