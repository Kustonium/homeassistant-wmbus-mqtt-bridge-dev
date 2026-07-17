# Development and Release

Maintainer reference for building, testing, and publishing **wMBus MQTT
Bridge**. Runtime behavior and the integration boundary with `wmbusmeters` are
documented in [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Repository roles

Development and stable releases live in separate repositories:

- **dev**: `homeassistant-wmbus-mqtt-bridge-dev` (this repository);
- **stable**: `homeassistant-wmbus-mqtt-bridge`.

`config.yaml` is the add-on version source of truth. The dev build workflow
derives `X.Y.Z-dev.<run_number>` from its current `X.Y.Z` core. A successful CI
run writes that exact built version back to `config.yaml`; a remembered or
manually inferred version is not authoritative.

## Dev build pipeline

`.github/workflows/build.yaml` runs for image-affecting changes and can also be
started manually. Documentation-only pushes are skipped by a path-aware gate.
For a build, the jobs are intentionally ordered so Home Assistant never sees a
version whose image failed validation:

1. **Static tests** verify the driver-catalog and Discovery publication
   contracts.
2. **Build** produces and pushes amd64 and aarch64 images tagged with the
   current CI run version.
3. **Manifest** publishes the additional architecture-neutral image used by
   standalone Docker.
4. **Decode smoke** runs the golden telegram fixtures inside the freshly built
   amd64 image.
5. **Standalone boot** starts that image next to Mosquitto using the documented
   Docker entrypoint and verifies the minimum boot contract.
6. **Bump** updates `config.yaml` only after both architecture builds, the
   manifest, decode smoke, and standalone boot have all passed.

If any required job fails, `config.yaml` remains on the previous working
version. Images from the failed run may exist under their run-specific tag, but
they are not advertised as the new add-on version.

## Upgrading wmbusmeters

### Fixed upstream pin

The [`Dockerfile`](../Dockerfile) builds upstream `wmbusmeters` from the full
commit named by `ARG WMBUSMETERS_COMMIT`. The clone is intentionally not shallow
because upstream derives its version through `git describe --tags`.

Do not replace the pin with upstream `master`. A release pin provides a
reproducible binary and a reviewable decoder change. The monthly
`.github/workflows/wmbusmeters-pin-bump.yml` workflow compares the current pin
with the latest upstream `X.Y.Z` release tag and opens a pull request when a new
release exists. Merging remains a human decision.

### Driver catalog contract

The Docker build creates `drivers.json` for the WebUI from:

- `wmbusmeters --listdrivers`, with `--listmeters` as a compatibility fallback;
- upstream XMQ definitions under `drivers/src/*.xmq`.

The image build fails unless the built-in `izar` driver is present. This check
protects the entire class of built-in drivers: a changed list command must not
silently leave the WebUI with only source-scanned XMQ drivers.

### Golden decode fixtures

`tests/test_decode_smoke.sh` reads `tests/fixtures/golden.tsv`. Each row names a
fixture directory/ID, driver, and key source. The matching `.hex` file contains
the RAW telegram and `.golden.json` contains normalized expected output.
`timestamp` and `name` are excluded from comparison.

Keys in the fixture table may be:

- `NOKEY`;
- a literal 32-character key only when that key is already public, such as an
  upstream test key;
- an environment-variable name supplied from repository secrets.

Private keys must never be committed or printed by CI. Meter IDs are passed to
`wmbusmeters` in lowercase because address matching is case-sensitive.

When an accepted upstream change intentionally alters decoded JSON, regenerate
the affected `.golden.json` with the pinned binary and review the field/value
change before committing it. `GOLDEN_REQUIRE=0` can be used temporarily to
print missing expected output, but it is not the normal protected build mode.

## Standalone Docker gate

The `standalone-boot` job starts the freshly built amd64 image with its default
`/usr/bin/docker-entrypoint.sh` and a Mosquitto container reachable as
`mosquitto`. It verifies that:

- `/config/options.json` is generated;
- `bridge.sh` connects to the broker;
- the container remains running.

This path is tested separately because Home Assistant uses s6 and does not run
the Docker entrypoint. A working add-on boot therefore does not prove the
standalone wrapper works.

## Promoting dev to stable

Promotion is a manual workflow in the stable repository. It copies the tested
implementation from dev while preserving stable repository identity and
release infrastructure.

Synced from dev:

- `rootfs/`;
- `Dockerfile`;
- `docker/`;
- `translations/`;
- `wmbusmeters-mqtt-stdin`;
- `README.md` and `docs/`;
- `THIRD_PARTY_NOTICES.md`;
- `config.yaml`, followed by restoration of stable identity fields.

Kept stable-specific:

- `.github/` workflows;
- `repository.yaml`;
- `config.yaml` identity fields such as name, slug, image, panel title, and
  description;
- `LICENSE`.

During promotion, the cycle's `## X.Y.Z-dev.NN` changelog sections are
consolidated into one `## X.Y.Z` section, with duplicate entries and dev markers
removed.

The broad sync set is deliberate. Earlier narrow promotion copied runtime code
but omitted files such as `config.yaml` and `docker/`, allowing driver schema and
standalone behavior to drift between dev and stable.

## Validation by change type

Before publishing a change, run the checks that match the files touched:

| Change | Minimum local validation |
|---|---|
| shell scripts | `bash -n`, ShellCheck, and focused runtime/static tests |
| Python | `python -m py_compile` plus focused endpoint/model checks |
| YAML | repository YAML lint workflow or equivalent local lint |
| Docker/build | local image build when practical; CI remains the architecture matrix authority |
| decoder pin or fixture | golden decode smoke and driver-catalog contract |
| documentation | link review and `git diff --check` |

CI is the publication gate, not a substitute for reviewing the actual decoded
field and value changes caused by a decoder upgrade.
