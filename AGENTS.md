# AGENTS.md — Repository Workflow Instructions

Instructions for Codex sessions working on this repository.

---

## 1. Public repository — professional standards

This repository is public. Commits, pull requests, and changelogs are visible to
external technical readers including maintainers of wmbusmeters, ESPHome, and
Home Assistant. Write every change as if it will be immediately reviewed by an
external maintainer.

---

## 2. Minimal, targeted changes only

- Change only the files necessary to solve the specific problem.
- Do not refactor unrelated code while working on a fix.
- Do not touch working logic without a confirmed bug report.
- Do not modify SPDX headers or licence markers.
- Do not redesign architecture when a small patch is sufficient.
- Diagnose first → propose the minimal fix → then write code.

---

## 3. No AI attribution in public commits

Do not add to any commit message:

```
Co-Authored-By: Codex ...
Generated-by: ...
AI-assisted: ...
```

The commit author takes responsibility for the code. Public commits document
technical changes, not the tools used during development.

---

## 4. Use exact technical names from the code

Never abbreviate state names, variable names, or file names. Use exactly the
names as they appear in the source:

| Correct | Incorrect |
|---|---|
| `decoded_without_numeric_value` | `decoded_without_numeric` |
| `no_decode_result` | `no decode` |
| `status_candidate_preview_state.tsv` | `preview state file` |
| `STATUS_CANDIDATE_PREVIEW_STATE_FILE` | `state file` |

---

## 5. Show plan before every commit

Before executing `git commit`, show the user:

1. Proposed commit title
2. Full commit body
3. List of changed files
4. `git diff --stat`
5. Validation results
6. Confirmation that no AI footer is present

Do not commit or push without explicit user approval.

---

## 6. Mandatory validation before every push

Run all of the following before pushing any bash-file changes:

```bash
bash -n rootfs/usr/bin/bridge.sh
bash -n rootfs/usr/bin/run.sh
bash -n docker/entrypoint.sh
bash -n tests/test_candidate_race.sh

shellcheck \
  docker/entrypoint.sh \
  rootfs/usr/bin/bridge.sh \
  rootfs/usr/bin/run.sh \
  tests/test_candidate_race.sh

git diff --check
git diff --stat
git status
```

If ShellCheck is not available locally, install it or run it in a container.
Do not wait for GitHub Actions to catch ShellCheck warnings. CI must pass before
merging.

---

## 7. Do not revert confirmed fixes without proof of regression

The following areas have been confirmed working and must not be modified without
a confirmed, reproducible bug:

- `flock + mktemp` for TSV serialisation (`_tsv_upsert`)
- Atomic `mv` for all TSV and counter file writes
- Debounced `.reload_listen` via `_request_listen_reload`
- Atomic pending marker using `mkdir`
- Cleanup of orphaned `.reload_listen_pending` at startup
- Parallel LISTEN instance always started unconditionally
- Automatic preview decoding for candidates (`ensure_candidate_autodecode`)
- Preview state transitions:
  - `pending`
  - `decoded_value`
  - `decoded_without_numeric_value`
  - `no_decode_result`
- Encryption badge rendering: `unknown` → grey "Nieustalone", not green

---

## 8. Current preview state machine

States:

```
pending
decoded_value
decoded_without_numeric_value
no_decode_result
```

Valid transitions:

```
pending          -> decoded_value                 (parallel LISTEN emits JSON with numeric value)
pending          -> decoded_without_numeric_value (parallel LISTEN emits JSON, no numeric value)
pending          -> no_decode_result              (count >= 3 text-only telegrams AND elapsed >= 60 s)
no_decode_result -> decoded_value                 (JSON arrives later)
no_decode_result -> decoded_without_numeric_value (JSON arrives later, no numeric value)
```

UI rendering:

```
pending                        -> "dekoduję..."
decoded_value                  -> numeric value
decoded_without_numeric_value  -> "brak wartości w telegramie"
no_decode_result               -> "brak wyniku dekodowania"
```

---

## 9. Commit message format — Conventional Commits

Use the following prefixes:

- `fix:` — bug fix with confirmed symptom
- `feat:` — new behaviour or state
- `docs:` — documentation only
- `test:` — test changes
- `refactor:` — restructuring without behaviour change

Commit title: short, technical, describes the real effect.

Commit body must state:

- what the problem was
- what the symptom was
- where the root cause was
- exactly what was changed
- what was deliberately not changed
- behaviour after the change

For state machine changes: include the full transition table.

---

## 10. Session handoff

At the end of a significant session, update:

```
docs/CLAUDE_HANDOFF.md
```

Include: what was fixed, commits pushed, files changed, tests run, manual test
results, and a ready-to-paste prompt for the next session.

---

## 11. Regression test corpus

Normal addon test replay:

```
01_strict_replay_all_validated.txt
```

Parameters: 40 structurally valid frames, 29 unique IDs, correct L-field,
even-length hex, hex characters only.

```bat
wmbus-mqtt-replay.exe -file 01_strict_replay_all_validated.txt -interval 5
```

Do not mix structurally inconsistent frames into the normal replay. Broken frames
belong in a separate torture-test corpus.

---

## 12. Version number — read it from disk, never from memory

Multiple agents (Codex CLI, Codex) and CI all push to this repo. Any version
number remembered from an earlier session or another tool is almost certainly
stale. Before writing a CHANGELOG heading, a release note, or anything that
states the version, determine the real version from the working tree.

Single source of truth:

```
config.yaml  →  version: "X.Y.Z-dev[.NN]"
```

Procedure (every time, no exceptions):

1. `git fetch` and make sure the branch is up to date, then read the current
   value from `config.yaml`:

   ```bash
   sed -nE 's/^version:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' config.yaml
   ```

2. The CHANGELOG section heading must be the **core** `X.Y.Z-dev` taken from that
   value (drop any `.NN` build suffix). Example: `config.yaml` says
   `1.5.22-dev.89` → the CHANGELOG heading is `## 1.5.22-dev`.

3. Do **not** invent the `.NN` build suffix by hand. CI's `bump` job derives
   `X.Y.Z-dev.<run_number>` from `config.yaml` and commits it
   (`ci(dev): bump version to ... [skip ci]`). Hand-writing a build number will
   collide with CI.

4. Only raise the **core** `X.Y.Z` when starting a new release cycle, and do it
   in `config.yaml` (the human/agent action mirrored by
   `chore: bump dev base to X.Y.Z-dev ...`). A CHANGELOG entry alone never bumps
   the version.

5. If the top CHANGELOG heading does not match the core version in
   `config.yaml`, fix the heading rather than appending under a guessed or
   placeholder section (e.g. `## Unreleased`).

Never take the version from this file, from session memory, or from a previous
agent's output. Read `config.yaml`.
