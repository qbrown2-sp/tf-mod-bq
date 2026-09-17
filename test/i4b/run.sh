#!/usr/bin/env bash
#
# I4B integration test: external-table hive_partitioning_options.require_partition_filter
#
# Builds a throwaway DDL repo with the I4B framework exactly as its README describes
# (i4b-helper init-project / provision-dataset), points I4B's tf-mod-bq module source at
# THIS checkout, and asserts that a `requirePartitionFilter` set in an external table's
# hivePartitioningOptions actually reaches the google_bigquery_table plan.
#
# Hermetic: uses a non-existent project/dataset so I4B finds nothing to import, which means
# no GCP API calls and no credentials are required. Runs the same way in CI and locally.
#
# Usage:
#   test/i4b/run.sh                     # test this checkout (expected: PASS)
#   MODULE_SOURCE=<tf source> test/i4b/run.sh
#                                       # test an arbitrary ref, e.g. to confirm the
#                                       # pre-fix module fails (expected: FAIL)
#
# Env:
#   I4B_REF        i4b revision to test against (default: the pin used by data-warehouse-ddl)
#   MODULE_SOURCE  override the tf-mod-bq module source
#   KEEP_WORK      set to 1 to keep the work directory for inspection

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT
readonly WORK="${REPO_ROOT}/test/i4b/.work"
readonly I4B_REF="${I4B_REF:-48c9815c8ab6c2e0da221256346d6b45b0a2ed9f}"

# A project that does not exist, so `i4b-helper get-component-lists` reports the dataset as
# absent and I4B generates no import blocks. Keeps the plan offline.
readonly PROJECT="i4b-hive-partition-test"
readonly DATASET="I4B_HIVE_TEST"
readonly ETABLE="HIVE_PARTITIONED_ET"

realpath_bin=$(type -p grealpath || type -p realpath)
readonly realpath_bin

log()  { printf '\033[0;32mINFO:\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

if ((BASH_VERSINFO[0] < 5)); then
  fail "Bash >= 5 required by i4b-helper; found ${BASH_VERSINFO[0]}"
fi

trap '[[ ${KEEP_WORK:-0} == 1 ]] || rm -rf "${WORK}"' EXIT
rm -rf "${WORK}"; mkdir -p "${WORK}"

# ---------------------------------------------------------------------------
# 1. Build a DDL repo the way the I4B README says to
# ---------------------------------------------------------------------------
cd "${WORK}"
git init -q ddlrepo
cd ddlrepo
git config user.email i4b-test@example.com
git config user.name "i4b test"

log "Cloning I4B at ${I4B_REF:0:8}"
git clone -q https://github.com/cbsi-dto/i4b.git i4b
git -C i4b checkout -q "${I4B_REF}"

# Supply the config directly rather than running `init-ddl-repo`, which would provision a
# GCS backend bucket and therefore require credentials. Equivalent to the README's -C path.
cat >i4b-conf.yaml <<EOF
dba_gsa: i4b-test@${PROJECT}.iam.gserviceaccount.com
backend:
  project: ${PROJECT}
  region: us-central1
EOF

log "i4b-helper init-project -p ${PROJECT}"
./i4b/i4b-helper init-project -u -p "${PROJECT}" >/dev/null

log "i4b-helper provision-dataset -d ${DATASET}"
(cd "bigquery/${PROJECT}" \
  && ../../i4b/i4b-helper provision-dataset -d "${DATASET}" \
       -s "I4B hive partitioning integration test" -f "I4B hive test" >/dev/null)

readonly TF_DIR="${WORK}/ddlrepo/bigquery/${PROJECT}/${DATASET}/terraform"

# ---------------------------------------------------------------------------
# 2. External table fixture: the flag under test
# ---------------------------------------------------------------------------
cat >"${WORK}/ddlrepo/bigquery/${PROJECT}/${DATASET}/etables/${ETABLE}.json" <<EOF
{
  "externalDataConfiguration": {
    "autodetect": true,
    "sourceFormat": "NEWLINE_DELIMITED_JSON",
    "sourceUris": ["gs://${PROJECT}-events/topics/Example/*.json"],
    "hivePartitioningOptions": {
      "mode": "AUTO",
      "sourceUriPrefix": "gs://${PROJECT}-events/topics/Example/",
      "requirePartitionFilter": true
    }
  },
  "description": "Fixture for DARCH-11318: require_partition_filter on an external table"
}
EOF

# ---------------------------------------------------------------------------
# 3. Point I4B at the module under test
# ---------------------------------------------------------------------------
if [[ -n ${MODULE_SOURCE:-} ]]; then
  module_source="${MODULE_SOURCE}"
  log "Module source (override): ${module_source}"
else
  # Relative path from the dataset's terraform dir to this checkout, so the test always
  # exercises the working tree rather than a pinned revision.
  module_source=$("${realpath_bin}" --relative-to "${TF_DIR}" "${REPO_ROOT}")
  log "Module source (this checkout): ${module_source}"
fi

i4b_main="${WORK}/ddlrepo/i4b/terraform/main.tf"
python3 - "${i4b_main}" "${module_source}" <<'PY'
import re, sys
path, source = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'(?m)^(\s*source\s*=\s*)"git::https://github\.com/[^"]*tf-mod-bq[^"]*"',
               lambda m: f'{m.group(1)}"{source}"', s)
if n != 1:
    sys.exit(f"expected exactly 1 tf-mod-bq module source in {path}, replaced {n}")
open(path, 'w').write(s)
PY

# I4B ships the external-table passthrough commented out, with the note "not supported yet by
# google module" -- this module change is what adds that support. Enable it, and require that
# the passthrough ends up present either way so this never degrades into a silent no-op.
python3 - "${i4b_main}" <<'PY'
import re, sys
path = sys.argv[1]
s = open(path).read()
pat = r'(?m)^(\s*)#\s*(require_partition_filter\s*=\s*lookup\(local\.etable_json)'
s, n = re.subn(pat, r'\1\2', s)
open(path, 'w').write(s)
hive = re.search(r'hive_partitioning_options = lookup\((.|\n)*?\n    \}', s)
if not hive or 'require_partition_filter' not in hive.group(0):
    sys.exit("i4b hive_partitioning_options block has no require_partition_filter passthrough; "
             "the upstream block shape changed and this test needs updating")
print(f"INFO: i4b etable passthrough enabled (uncommented {n} line(s))")
PY

# provision-dataset writes a GCS backend; use local state so no credentials are needed.
mv "${TF_DIR}/backend.tf" "${TF_DIR}/backend.tf.disabled"
rm -f "${TF_DIR}/.terraform.lock.hcl"

# ---------------------------------------------------------------------------
# 4. Plan and assert
# ---------------------------------------------------------------------------
cd "${TF_DIR}"
log "terraform init"
terraform init -no-color -upgrade >"${WORK}/init.log" 2>&1 \
  || { cat "${WORK}/init.log"; fail "terraform init failed"; }

log "terraform plan"
if ! terraform plan -no-color -input=false >"${WORK}/plan.log" 2>&1; then
  cat "${WORK}/plan.log"
  fail "terraform plan failed"
fi

hive_block=$(awk '/hive_partitioning_options \{/{f=1} f{print} f&&/^ *\}/{exit}' "${WORK}/plan.log")
if [[ -z ${hive_block} ]]; then
  cat "${WORK}/plan.log"
  fail "no hive_partitioning_options block in the plan"
fi

echo
echo "--- planned hive_partitioning_options ---"
echo "${hive_block}"
echo "-----------------------------------------"
echo

if ! grep -qE 'require_partition_filter\s*=\s*true' <<<"${hive_block}"; then
  fail "require_partition_filter is missing from the planned hive_partitioning_options.
The external table requested requirePartitionFilter=true but it did not reach the resource.
Note that Terraform silently discards object attributes absent from a declared object type,
so this failure mode produces no error and 'terraform validate' still succeeds."
fi

log "PASS: require_partition_filter=true reached google_bigquery_table via I4B"
