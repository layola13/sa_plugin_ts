#!/usr/bin/env bash
# End-to-end verification for sa_plugin_ts.
#
# The Zig unit tests assert on substrings of the lowerer output, which cannot
# detect an instruction the SA assembler rejects. This script closes that gap:
# it lowers a set of TypeScript programs and runs `sa build` on the result, so
# any regression in emitted SA-ASM fails here.
#
# Usage: tools/verify_e2e.sh
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
if [[ ! -f "$SA_PLUGINS_PATH/libsa_plugin_ts.so" ]]; then
  echo "error: plugin not built; run 'zig build' in $PLUGIN_DIR" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() {
  local name="$1" src="$2"
  printf '%s' "$src" > "$WORK/case.ts"

  if ! "$SA_BIN" ts lower --out "$WORK/case.sai" "$WORK/case.ts" 2> "$WORK/lower.err"; then
    echo "FAIL $name (lower)"; sed 's/^/    /' "$WORK/lower.err"; fail=$((fail+1)); return
  fi
  if [[ -s "$WORK/lower.err" ]]; then
    echo "WARN $name (lower diagnostics)"; sed 's/^/    /' "$WORK/lower.err"
  fi

  # `sa build` runs the verifier and then the backend. A missing entry point
  # fails only at link time, which still proves verification passed.
  if "$SA_BIN" build "$WORK/case.sai" > "$WORK/build.out" 2>&1; then
    echo "PASS $name"; pass=$((pass+1))
  elif grep -q 'ExternalCompiler' "$WORK/build.out"; then
    echo "PASS $name (verifier ok; link needs an entry point)"; pass=$((pass+1))
  else
    echo "FAIL $name (assemble)"
    grep -o 'error\[[A-Za-z]*\][^,]*' "$WORK/build.out" | head -1 | sed 's/^/    /'
    fail=$((fail+1))
  fi
}

check "if/else" 'function sign(x: i32): i32 { if (x < 0) { return 0 - 1; } else { return 1; } }'
check "if without else" 'function pos(x: i32): i32 { let r: i32 = 0; if (x > 0) { r = 1; } return r; }'
check "while" 'function sum(n: i32): i32 { let t: i32 = 0; let i: i32 = 0; while (i < n) { t = t + i; i = i + 1; } return t; }'
check "c-style for" 'function main(): i32 { let t: i32 = 0; for (let i: i32 = 0; i < 5; i++) { t = t + i; } return t; }'
check "for-of" 'function main(): i32 { let a = [1,2,3]; let t: i32 = 0; for (const v of a) { t = t + v; } return t; }'
check "switch with default" 'function pick(a: i32): i32 { let r: i32 = 0; switch (a) { case 1: { r = 10; break; } case 2: { r = 20; break; } default: { r = 99; } } return r; }'
check "switch unbraced" 'function pick(a: i32): i32 { let r: i32 = 0; switch (a) { case 1: r = 10; break; default: r = 99; } return r; }'
check "typed array literal" 'function main(): i32 { let a: i32[] = [1,2,3]; return a[1]; }'
check "array store" 'function main(): i32 { let a: i32[] = [1,2,3]; a[1] = 9; return a[1]; }'
check "struct field access" 'interface P { x: i32; y: i32; }
function main(): i32 { const p: P = { x: 3, y: 4 }; return p.x; }'
check "nested control flow" 'function main(): i32 { let t: i32 = 0; for (let i: i32 = 0; i < 3; i++) { if (i > 1) { t = t + i; } else { t = t + 0; } } return t; }'
check "void function, moved value" 'function logIt(x: i32) { let y: i32 = x; }'
check "no return, heap local" 'interface P { x: i32; }
function main() { let p: P = { x: 1 }; p.x = 2; }'
check "scalar locals" 'function main(): i32 { let a: i32 = 1; let b: i32 = 2; return a + b; }'

# Merge-label and dead-code shapes. A merge label is dropped only when both arms
# terminate; emitting or omitting it wrongly shows up as FallthroughForbidden or
# as register releases landing after a terminator. These are the shapes most
# likely to produce silently wrong control flow, so each is assembled for real.
check "early-return if, then trailing code" 'function f(x: i32): i32 { if (x > 0) { return 1; } return 2; }'
check "if/else both return" 'function sign(x: i32): i32 { if (x < 0) { return 0 - 1; } else { return 1; } }'
check "if both arms return, trailing stmt" 'function g(x: i32): i32 { if (x > 0) { return 1; } else { return 2; } return 3; }'
check "nested early returns" 'function h(x: i32): i32 { if (x > 0) { if (x > 5) { return 2; } return 1; } return 0; }'
check "loop with early return" 'function k(n: i32): i32 { let i: i32 = 0; while (i < n) { if (i == 2) { return 7; } i = i + 1; } return 0; }'
check "break inside nested if in loop" 'function m(n: i32): i32 { let i: i32 = 0; let t: i32 = 0; while (i < n) { if (i > 1) { break; } t = t + i; i = i + 1; } return t; }'
check "multiple functions, distinct labels" 'function a(x: i32): i32 { if (x > 0) { return 1; } return 0; }
function b(x: i32): i32 { if (x > 0) { return 2; } return 0; }
function c(x: i32): i32 { let t: i32 = 0; for (let i: i32 = 0; i < x; i++) { t = t + i; } return t; }'
check "switch with return in cases" 'function d(a: i32): i32 { switch (a) { case 1: { return 10; } case 2: { return 20; } default: { return 0; } } }'

check "literal template string" 'function greet() { const msg: string = `hello world`; }'

# Interpolated templates are recognised but not lowerable: an SA-ASM string is a
# {ptr,len} slice, so joining chunks needs @sa_fmt_i64_into + @sa_string_concat.
# The lowerer must report a diagnostic instead of emitting a `concat`
# instruction, which is not an SA mnemonic.
printf '%s' 'function main() { const s: string = `sum=${1}`; }' > "$WORK/tpl.ts"
if "$SA_BIN" ts lower --out "$WORK/tpl.sai" "$WORK/tpl.ts" 2> "$WORK/tpl.err"; then
  if grep -q 'interpolated template' "$WORK/tpl.err" && ! grep -q 'concat' "$WORK/tpl.sai"; then
    echo "PASS interpolated template reports a diagnostic (no bogus concat)"; pass=$((pass+1))
  else
    echo "FAIL interpolated template (expected a diagnostic and no 'concat' in output)"
    sed 's/^/    /' "$WORK/tpl.err"; fail=$((fail+1))
  fi
else
  echo "FAIL interpolated template (lower)"; sed 's/^/    /' "$WORK/tpl.err"; fail=$((fail+1))
fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
