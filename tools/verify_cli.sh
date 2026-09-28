#!/usr/bin/env bash
# Smoke tests for the sa_plugin_ts CLI surface.
# Mirrors the conventions documented in sala (sa sla): [file] optional with
# sa.mod workspace fallback, -p name/-p=name/--package=name, direct
# passthrough to delegated sa commands with automatic --jobs auto.
# Usage: tools/verify_cli.sh
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
# Dev-mode flag (mirrors sa_plugin_sla sweep scripts): zig-out/lib now ships
# sap.json, so the host treats it as a manifest-backed plugin dir and requires
# dev mode (permissions.lock) instead of the bare-.so lenient path.
export SA_PLUGIN_DEV=1
export SA_EXE="$SA_BIN"
if [[ ! -f "$SA_PLUGINS_PATH/libsa_plugin_ts.so" ]]; then
  echo "error: plugin not built; run 'zig build' in $PLUGIN_DIR" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

# NOTE: help goes to stderr (same convention as `sa sla help`).
if "$SA_BIN" ts help 2>&1 | grep -q "build-exe" && "$SA_BIN" ts help 2>&1 | grep -q "init "; then ok "help lists build-exe/test/init"; else bad "help lists build-exe/test/init"; fi
if "$SA_BIN" ts skills --json 2>/dev/null | grep -q "ts.build-exe" && "$SA_BIN" ts skills --json 2>/dev/null | grep -q "ts.init"; then ok "skills --json lists build-exe/init"; else bad "skills --json lists build-exe/init"; fi
if "$SA_BIN" ts frobnicate >/dev/null 2>&1; then bad "unknown subcommand rejected"; else ok "unknown subcommand rejected"; fi
if "$SA_BIN" ts lower a.ts b.ts >/dev/null 2>&1; then bad "stray positional rejected"; else ok "stray positional rejected"; fi

DEMO="$PLUGIN_DIR/demos/023_if_else_max/main.ts"
if "$SA_BIN" ts check "$DEMO" >/dev/null 2>&1; then ok "check"; else bad "check"; fi
if "$SA_BIN" ts build --out "$WORK/b.sai" "$DEMO" >/dev/null 2>&1 && [[ -s "$WORK/b.sai" ]]; then ok "build writes .sai"; else bad "build writes .sai"; fi
# build-exe passes -o straight through to sa build-exe; result matches Node
if "$SA_BIN" ts build-exe "$DEMO" -o "$WORK/b.exe" >/dev/null 2>&1; then
  "$WORK/b.exe" >/dev/null 2>&1; rc=$?
  python3 "$PLUGIN_DIR/tools/strip_ts.py" "$DEMO" "$WORK/c.mjs" 2>/dev/null && oracle=$(node "$WORK/c.mjs" 2>/dev/null) || oracle=""
  if [[ -n "$oracle" ]]; then
    want=$(( (oracle % 256 + 256) % 256 ))
    if [[ "$rc" == "$want" ]]; then ok "build-exe matches node (status $rc)"; else bad "build-exe matches node (sa=$rc node=$oracle)"; fi
  else
    ok "build-exe links and runs (no node oracle)"
  fi
  if ls "$WORK"/.ts-tmp-* 2>/dev/null | grep -q .; then bad "temp .sai cleaned up"; else ok "temp .sai cleaned up"; fi
else
  bad "build-exe links"
fi
if "$SA_BIN" ts test "$DEMO" 2>&1 | grep -q "test result"; then ok "test delegates to sa test"; else bad "test delegates to sa test"; fi
# value-taking flags pass through with their values (not mistaken for the file)
if "$SA_BIN" ts test "$DEMO" --jobs 1 2>&1 | grep -q "test result"; then ok "passthrough --jobs 1"; else bad "passthrough --jobs 1"; fi

# --- init: scaffold, no-overwrite, arg validation ---
if "$SA_BIN" ts init "$WORK/proj" >/dev/null 2>&1 && [[ -f "$WORK/proj/sa.mod" && -f "$WORK/proj/src/main.ts" && -f "$WORK/proj/.gitignore" ]]; then ok "init scaffolds sa.mod/src/main.ts/.gitignore"; else bad "init scaffolds sa.mod/src/main.ts/.gitignore"; fi
if grep -q 'package "proj"' "$WORK/proj/sa.mod" 2>/dev/null; then ok "init package name from basename"; else bad "init package name from basename"; fi
if "$SA_BIN" ts init "$WORK/proj" >/dev/null 2>&1; then bad "init refuses to overwrite"; else ok "init refuses to overwrite"; fi
if "$SA_BIN" ts init a b >/dev/null 2>&1; then bad "init rejects two paths"; else ok "init rejects two paths"; fi
if "$SA_BIN" ts init --foo >/dev/null 2>&1; then bad "init rejects flags"; else ok "init rejects flags"; fi
# scaffolded entry lowers and runs
if "$SA_BIN" ts build-exe "$WORK/proj/src/main.ts" -o "$WORK/proj_main" >/dev/null 2>&1 && "$WORK/proj_main" >/dev/null 2>&1; [[ $? == 0 ]]; then ok "scaffolded main builds and runs"; else bad "scaffolded main builds and runs"; fi

# --- workspace: omitted file resolves via sa.mod ---
WS="$WORK/ws"
mkdir -p "$WS/members/app/src" "$WS/members/tool/src"
printf 'workspace {\n  members ["members/app", "members/tool"]\n  default_member "app"\n}\n' > "$WS/sa.mod"
printf 'package "app"\n' > "$WS/members/app/sa.mod"
printf 'function main(): i32 {\n  return 7;\n}\n' > "$WS/members/app/src/main.ts"
printf 'package "tool"\n' > "$WS/members/tool/sa.mod"
printf 'function main(): i32 {\n  return 9;\n}\n' > "$WS/members/tool/src/main.ts"
if (cd "$WS" && "$SA_BIN" ts check 2>&1 | grep -q "members/app/src/main.ts"); then ok "workspace default member"; else bad "workspace default member"; fi
if (cd "$WS" && "$SA_BIN" ts check -p tool 2>&1 | grep -q "members/tool/src/main.ts"); then ok "-p member"; else bad "-p member"; fi
if (cd "$WS" && "$SA_BIN" ts check -p=tool 2>&1 | grep -q "members/tool/src/main.ts"); then ok "-p= form"; else bad "-p= form"; fi
if (cd "$WS" && "$SA_BIN" ts check --package=app 2>&1 | grep -q "members/app/src/main.ts"); then ok "--package= form"; else bad "--package= form"; fi
if (cd "$WS" && "$SA_BIN" ts check -p nope >/dev/null 2>&1); then bad "unknown package rejected"; else ok "unknown package rejected"; fi
if (cd "$WS/members/tool" && "$SA_BIN" ts check 2>&1 | grep -q "members/tool/src/main.ts"); then ok "member-dir fallback"; else bad "member-dir fallback"; fi
if (cd "$WS" && "$SA_BIN" ts build-exe -o "$WORK/ws_app" >/dev/null 2>&1 && "$WORK/ws_app" >/dev/null 2>&1; [[ $? == 7 ]]); then ok "build-exe workspace default (status 7)"; else bad "build-exe workspace default (status 7)"; fi
if (cd /tmp && "$SA_BIN" ts check >/dev/null 2>&1); then bad "no-workspace check rejected"; else ok "no-workspace check rejected"; fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
