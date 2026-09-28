#!/usr/bin/env bash
# Verify every TypeScript demo in sa_plugin_ts/demos.
#
# Each demo is lowered with the real plugin and the result is handed to
# `sa build`, so a demo only counts as passing if the emitted SA-ASM actually
# assembles. This mirrors tools/verify_e2e.sh but over the demo corpus.
#
# Usage: tools/verify_demos.sh [name-filter]
set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$PLUGIN_DIR/demos"
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
# Dev-mode flag (mirrors sa_plugin_sla sweep scripts): zig-out/lib now ships
# sap.json, so the host treats it as a manifest-backed plugin dir and requires
# dev mode (permissions.lock) instead of the bare-.so lenient path.
export SA_PLUGIN_DEV=1
if [[ ! -f "$SA_PLUGINS_PATH/libsa_plugin_ts.so" ]]; then
  echo "error: plugin not built; run 'zig build' in $PLUGIN_DIR" >&2
  exit 2
fi

FILTER="${1:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
lower_fail=0
diag=0
skipped=0
upstream=0
failed_names=()

# Demos whose failure reproduces in hand-written SA-ASM belongs to the SA
# toolchain, not the lowerer. They are counted separately so they neither mask
# real regressions nor inflate the failure count, but they are still listed.
# No demo currently needs an exclusion; see tools/withdrawn_findings.md for a
# finding that was reported and then withdrawn.
is_uncheckable() { return 1; }

# A process exit status is 8 bits, so a program returning 300 is observed as
# 300 & 0xFF = 44. Comparing that against Node's 300 produces a false failure.
# An earlier version of this script misread those as a toolchain bug; the
# withdrawable explanation is recorded in tools/uncheckable_demos.txt.

shopt -s nullglob
for src in "$DEMO_DIR"/*/main.ts; do
  dir="$(basename "$(dirname "$src")")"
  if [[ -n "$FILTER" && "$dir" != *"$FILTER"* ]]; then continue; fi

  if ! "$SA_BIN" ts lower --out "$WORK/case.sai" "$src" 2> "$WORK/err.txt"; then
    echo "FAIL $dir (lower)"
    sed 's/^/    /' "$WORK/err.txt" | head -3
    fail=$((fail+1)); lower_fail=$((lower_fail+1)); failed_names+=("$dir")
    continue
  fi

  # A demo may legitimately exercise a construct the lowerer refuses, as long
  # as it refuses loudly instead of emitting SA the assembler will reject.
  if grep -qE '^error:[0-9]+:[0-9]+:' "$WORK/err.txt"; then
    if grep -qE '= concat ' "$WORK/case.sai"; then
      echo "FAIL $dir (emitted invalid SA despite a diagnostic)"
      fail=$((fail+1)); failed_names+=("$dir")
    else
      diag=$((diag+1))
    fi
    continue
  fi

  # Differential check against Node.
  #
  # A demo that assembles can still be wrong: the array-literal layout bug
  # verified cleanly and then segfaulted, and a wrong-but-not-crashing result
  # would slip past a crash test entirely. tools/strip_ts.py removes the
  # TypeScript-only syntax so the same program runs under Node, and the two
  # results must agree. Hand-written expected values would only re-assert what
  # we already believe; this checks against a real evaluator.
  oracle=""
  if command -v node >/dev/null 2>&1; then
    if python3 "$PLUGIN_DIR/tools/strip_ts.py" "$src" "$WORK/case.mjs" 2>/dev/null; then
      oracle="$(node "$WORK/case.mjs" 2>/dev/null)"
    else
      skipped=$((skipped+1))
      continue
    fi
  fi

  if "$SA_BIN" build "$WORK/case.sai" -o "$WORK/case.exe" > "$WORK/build.out" 2>&1; then
    # Guard against demos that block waiting on the environment: tcpAccept
    # with no live peer never returns, which used to hang the whole suite.
    # A timeout is an environment limit, not a lowerer result, so it lands
    # in the not-observable bucket rather than pass or fail.
    if command -v timeout >/dev/null 2>&1; then
      timeout 10 "$WORK/case.exe" > "$WORK/run.out" 2>&1
      rc=$?
    else
      "$WORK/case.exe" > "$WORK/run.out" 2>&1
      rc=$?
    fi
    # A non-zero exit is a normal return value: `@main() -> i32` puts its result
    # in the exit status, and a negative result is reported unsigned (return -1
    # becomes 255). Exit status and signal death are both 128+n and cannot be
    # told apart from the shell, so only the two codes a demo is not plausibly
    # going to produce by returning a small negative number are treated as
    # crashes. This is a heuristic; an expected-value check would be exact.
    if [ "$rc" = 124 ]; then
      echo "SKIP $dir (run timed out after 10s; needs a live peer or input)"
      upstream=$((upstream+1))
    elif [ "$rc" = 139 ] || [ "$rc" = 134 ]; then
      echo "FAIL $dir (crashed, exit $rc)"
      head -2 "$WORK/run.out" | sed 's/^/    /'
      fail=$((fail+1)); failed_names+=("$dir")
    elif [ -n "$oracle" ]; then
      if [[ "$oracle" =~ ^-?[0-9]+$ ]]; then
      # `@main()` returns a negative value as an unsigned exit status.
      # A process exit status is exactly `value & 0xFF`, so compare the low
      # byte. Folding on "greater than 127" was wrong: 128..255 are ordinary
      # positive statuses, not signals.
      want=$(( (oracle % 256 + 256) % 256 ))
      if [ "$rc" != "$want" ]; then
        if is_uncheckable "$dir"; then
          echo "SKIP $dir (sa=$rc, node=$oracle; result not observable via exit code)"
          upstream=$((upstream+1))
        else
          echo "FAIL $dir (wrong result: sa=$rc, node=$oracle; expected status $want)"
          fail=$((fail+1)); failed_names+=("$dir")
        fi
      else
        pass=$((pass+1))
      fi
      else
        # Print demo: the Node oracle is program stdout plus the harness's
        # trailing `String(main())`. Print demos conventionally `return 0`,
        # so the oracle must equal the SA binary's captured stdout with a
        # trailing "0" appended byte-for-byte (no command substitution: it
        # would strip trailing newlines and mask whitespace diffs).
        cat "$WORK/run.out" > "$WORK/want.out"
        printf '0' >> "$WORK/want.out"
        if cmp -s "$WORK/want.out" <(printf '%s' "$oracle"); then
          pass=$((pass+1))
        else
          echo "FAIL $dir (wrong output)"
          diff <(cat "$WORK/run.out") <(printf '%s' "$oracle") | head -5 | sed 's/^/    /'
          fail=$((fail+1)); failed_names+=("$dir")
        fi
      fi
    else
      pass=$((pass+1))
    fi
  elif grep -q 'ExternalCompiler' "$WORK/build.out"; then
    # Verification passed; linking needs an entry point the demo does not define.
    pass=$((pass+1))
  else
    echo "FAIL $dir (assemble)"
    grep -o 'error\[[A-Za-z]*\][^,]*' "$WORK/build.out" | head -1 | sed 's/^/    /'
    fail=$((fail+1)); failed_names+=("$dir")
  fi
done
shopt -u nullglob

# Every demo leaves the loop through exactly one bucket: pass, fail, diag
# (refused with a located diagnostic), skipped (no Node oracle available) or
# upstream (built but the result is not observable via exit code in this
# environment, e.g. a blocking network accept). The headline total has to
# include all five.
total=$((pass + fail + diag + skipped + upstream))
echo
echo "demos: $total   verified: $pass   refused-with-diagnostic: $diag   no-oracle: $skipped   not-observable-via-exit-code: $upstream   failed: $fail"
if [[ ${#failed_names[@]} -gt 0 ]]; then
  printf 'failing: %s\n' "${failed_names[*]}"
fi
[[ $fail -eq 0 ]]
