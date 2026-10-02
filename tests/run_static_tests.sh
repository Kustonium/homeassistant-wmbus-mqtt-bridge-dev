#!/usr/bin/env bash
# The static regression suite, in one place for both CI workflows: build.yaml
# runs it before building an image on main, static-tests.yml runs it on every
# pull request so a regression is caught before the merge. Add a test here and
# both pick it up.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

bash tests/test_driver_catalog_contract.sh
bash tests/test_discovery_publish_order.sh
bash tests/test_discovery_field_categories.sh
bash tests/test_issue_report_sources.sh
bash tests/test_calculated_fields.sh
bash tests/test_esp_reception_history.sh
bash tests/test_esp_boot_dedup.sh
bash tests/test_esp_diag_retained.sh
bash tests/test_esp_coverage_sensor.sh
bash tests/test_mbus_meter_files.sh
bash tests/test_perf_fork_budget.sh
python3 -m unittest tests/test_mbus_webui.py -v
python3 -m unittest tests/test_meter_rename.py -v
