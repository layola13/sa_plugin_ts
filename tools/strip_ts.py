#!/usr/bin/env python3
"""Strip the TypeScript-only syntax from a demo so Node can execute it.

This produces an independent oracle for the SA-ASM backend: the same program is
run under Node and under the compiled SA binary, and the two results must agree.
Hand-written expected values would only assert what we already believe, whereas
this checks the backend against a real TypeScript/JavaScript evaluator.

Only the constructs this corpus uses are handled; anything else is left in place
so Node reports a syntax error rather than silently disagreeing.
"""
import re
import sys


def strip(src: str) -> str:
    out = src

    # import ... from "fs" / "net"  -> the SA backend maps these to primitives
    out = re.sub(r'^\s*import\s*\{[^}]*\}\s*from\s*"[^"]*"\s*;?\s*$', '', out, flags=re.M)

    # interface Name { ... }   (non-nested, non-exported)
    out = re.sub(r'^\s*(?:export\s+)?interface\s+\w+(?:<[^>]*>)?\s*\{[^}]*\}\s*', '', out, flags=re.M)

    # type Name = ...;   and   type Name<T> = ...;
    out = re.sub(r'^\s*type\s+\w+(?:<[^>]*>)?\s*=\s*[^;]+;\s*$', '', out, flags=re.M)

    # enum Name { A, B }  ->  const Name = { A: 0, B: 1 };
    def enum_repl(m):
        body = m.group(2)
        names = [n.strip() for n in body.split(',') if n.strip()]
        pairs = ', '.join('%s: %d' % (n, i) for i, n in enumerate(names))
        return 'const %s = { %s };\n' % (m.group(1), pairs)
    out = re.sub(r'^\s*enum\s+(\w+)\s*\{([^}]*)\}\s*', enum_repl, out, flags=re.M)

    # function f(a: i32, b: i32): i32 {   ->   function f(a, b) {
    TS_TYPE = r"(?:\w+)(?:<[^>]*>)?(?:\[\])?(?:\[\])?"
    out = re.sub(r'(function\s+\w+\s*\()([^)]*?)(\)\s*)(:\s*' + TS_TYPE + r')?(\s*\{)',
                 lambda m: m.group(1) +
                           re.sub(r':\s*' + TS_TYPE, '', m.group(2)) +
                           m.group(3) + (m.group(5) if m.group(5) else '{'),
                 out)

    # const/let name: Type = expr   /   name: Type = expr
    out = re.sub(r'^(\s*)((?:const|let|var)\s+\w+\s*):\s*' + TS_TYPE + r'(\s*=)',
                 r'\1\2\3', out, flags=re.M)
    out = re.sub(r'^(\s*)(\w+)\s*:\s*' + TS_TYPE + r'(\s*=)', r'\1\2\3', out, flags=re.M)

    # for (let i: i32 = 0; ...)  ->  for (let i = 0; ...)
    # The line-anchored rules above miss declarations inside a for header, so
    # those demos kept their annotations and Node rejected them with a
    # SyntaxError, leaving an empty oracle that verify_demos.sh auto-passes.
    out = re.sub(r'(\bfor\s*\(\s*(?:const|let|var)\s+\w+)\s*:\s*' + TS_TYPE + r'(?=\s*=)',
                 r'\1', out)

    # (x: i32) => ...  /  (a: i32, b) => ...  ->  (x) => ...  /  (a, b) => ...
    # Without this, arrow demos keep their annotations and Node rejects them
    # with a SyntaxError, leaving an empty oracle that verify_demos.sh
    # auto-passes without a real differential check.
    out = re.sub(r'\(([^()\n]*?)\)(\s*=>)',
                 lambda m: '(' + re.sub(r':\s*' + TS_TYPE, '', m.group(1)) + ')' + m.group(2),
                 out)

    return out


HARNESS = """
const __r = (typeof main === 'function') ? main() : 0;
process.stdout.write(String(__r === undefined ? 0 : __r));
"""


def main():
    if len(sys.argv) < 2:
        print("usage: strip_ts.py <main.ts> [out.mjs]", file=sys.stderr)
        return 2
    src = open(sys.argv[1], encoding='utf-8').read()
    body = strip(src) + HARNESS
    if len(sys.argv) > 2:
        open(sys.argv[2], 'w', encoding='utf-8').write(body)
    else:
        sys.stdout.write(body)
    return 0


if __name__ == '__main__':
    sys.exit(main())
