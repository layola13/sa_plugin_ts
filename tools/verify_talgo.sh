#!/usr/bin/env bash
# Sweep TheAlgorithms/TypeScript through `sa ts lower` and report coverage.
#
# Library files have no `main`, so (unlike verify_demos.sh) there is no
# Node differential here: a file counts as clean when lowering emits no
# `error:` diagnostic. Test harnesses (`test/` dirs, `*.test.ts`,
# `jest.config.ts`) need the jest runtime and are counted separately, never
# as failures.
#
# Regression rule: tools/talgo_expected_clean.txt lists every source file
# that lowers clean today. The script FAILS if any listed file newly errors
# (a real regression). Newly fixed files are reported but do not fail; add
# them to the list when fixed.
#
# Usage: tools/verify_talgo.sh [talgo-dir]
#   TALGO_DIR env or arg, else clones a shallow copy next to the plugin.
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SA_BIN="${SA_BIN:-}"
if [[ -z "$SA_BIN" ]]; then
  for cand in /content/sa_all/sci/zig-out/bin/sa "$(command -v sa || true)"; do
    [[ -x "$cand" ]] && SA_BIN="$cand" && break
  done
fi
if [[ ! -x "$SA_BIN" ]]; then
  echo "error: sa binary not found; set SA_BIN" >&2
  exit 2
fi

export SA_PLUGINS_PATH="$PLUGIN_DIR/zig-out/lib"
export SA_PLUGIN_DEV=1
if [[ ! -f "$SA_PLUGINS_PATH/libsa_plugin_ts.so" ]]; then
  echo "error: plugin not built; run 'zig build' in $PLUGIN_DIR" >&2
  exit 2
fi

TALGO_DIR="${1:-${TALGO_DIR:-}}"
if [[ -z "$TALGO_DIR" ]]; then
  TALGO_DIR="/tmp/opencode/TheAlgorithms-TypeScript"
fi
if [[ ! -d "$TALGO_DIR" ]]; then
  echo "cloning TheAlgorithms/TypeScript into $TALGO_DIR ..."
  git clone --depth 1 https://github.com/TheAlgorithms/TypeScript "$TALGO_DIR" >&2 || exit 2
fi

EXPECTED="$PLUGIN_DIR/tools/talgo_expected_clean.txt"
FILTER="${2:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

clean=0
dirty=0
test_total=0
test_dirty=0
dirty_names=()
regressions=()
fixed=()

while IFS= read -r -d '' src; do
  rel="${src#$TALGO_DIR/}"
  if [[ -n "$FILTER" && "$rel" != *"$FILTER"* ]]; then continue; fi
  # Test/config bucket: jest runtime territory, never a failure.
  if [[ "$rel" == *"/test/"* || "$rel" == *".test."* || "$rel" == *"jest.config"* ]]; then
    test_total=$((test_total+1))
    if ! timeout 30 "$SA_BIN" ts lower --out "$WORK/out.sai" "$src" 2> "$WORK/err.txt" >/dev/null \
      || grep -qE '^error:[0-9]+:[0-9]+:' "$WORK/err.txt"; then
      test_dirty=$((test_dirty+1))
    fi
    continue
  fi
  if timeout 30 "$SA_BIN" ts lower --out "$WORK/out.sai" "$src" 2> "$WORK/err.txt" >/dev/null \
    && ! grep -qE '^error:[0-9]+:[0-9]+:' "$WORK/err.txt"; then
    clean=$((clean+1))
  else
    dirty=$((dirty+1))
    dirty_names+=("$rel")
  fi
done < <(find "$TALGO_DIR" -name '*.ts' -print0 | sort -z)

echo "talgo src: clean $clean, with-error $dirty (of $((clean+dirty)))"
echo "talgo test/config: $test_total files, $test_dirty with diagnostics (expected: jest runtime)"
if [[ "$dirty" -gt 0 ]]; then
  echo "--- src files with diagnostics ---"
  printf '%s\n' "${dirty_names[@]}"
fi

rc=0
if [[ -f "$EXPECTED" ]]; then
  while IFS= read -r want || [[ -n "$want" ]]; do
    [[ -z "$want" || "$want" == \#* ]] && continue
    if printf '%s\n' "${dirty_names[@]}" | grep -qxF "$want"; then
      echo "REGRESSION: previously clean file now errors: $want"
      regressions+=("$want")
      rc=1
    fi
  done < "$EXPECTED"
  # Newly fixed: clean now but absent from the list (informational only).
  while IFS= read -r -d '' src; do
    rel="${src#$TALGO_DIR/}"
    if [[ "$rel" == *"/test/"* || "$rel" == *".test."* || "$rel" == *"jest.config"* ]]; then continue; fi
    if ! printf '%s\n' "${dirty_names[@]}" | grep -qxF "$rel"; then
      if ! grep -qxF "$rel" "$EXPECTED" 2>/dev/null; then
        fixed+=("$rel")
      fi
    fi
  done < <(find "$TALGO_DIR" -name '*.ts' -print0 | sort -z)
  if [[ "${#fixed[@]}" -gt 0 ]]; then
    echo "--- newly clean (consider adding to $EXPECTED) ---"
    printf '%s\n' "${fixed[@]}"
  fi
  if [[ "${#regressions[@]}" -eq 0 ]]; then
    echo "no regressions vs $EXPECTED"
  fi
else
  echo "note: no $EXPECTED yet; run with GENERATE=1 to create it"
  if [[ "${GENERATE:-}" == "1" ]]; then
    echo "not implemented here; list clean files manually" >&2
  fi
fi
exit "$rc"
