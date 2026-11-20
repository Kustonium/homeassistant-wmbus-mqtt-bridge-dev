#!/usr/bin/env bash
# app.js must not use a variable that does not exist where it is used.
#
# 1.6.23 shipped `reportedIdNote(row)` inside the ignored-candidates list,
# which maps bare ids and has no `row`: with one ignored candidate the
# Received page threw a ReferenceError and never rendered. The Python tests
# do not run app.js, and the code path only runs with data the bench did not
# have, so ESLint's no-undef checks the whole file instead.
#
# morphdom is a global from morphdom.min.js (vendored, not checked).
# ESLint is pinned and fetched with npx; without npx (a local run) the test
# is skipped, in CI it fails.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if ! command -v npx >/dev/null 2>&1; then
  if [[ -n "${CI:-}" ]]; then
    echo "FAIL: npx not found (needed for the app.js no-undef check)" >&2
    exit 1
  fi
  echo "SKIP: npx not found, app.js no-undef check not run"
  exit 0
fi

npx --yes eslint@8.57.0 --no-eslintrc \
  --env browser,es2022 --parser-options=ecmaVersion:2022 \
  --global morphdom \
  --rule 'no-undef:error' \
  rootfs/usr/share/wmbus-webui/assets/app.js
echo "OK: app.js has no undefined variables"
