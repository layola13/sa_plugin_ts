#!/usr/bin/env python3
"""Generate the sa_plugin_ts TypeScript demo corpus.

Each demo is a self-contained TypeScript program exercising one language
feature, laid out like the sa_plugin_sla rosetta demos:

    demos/<NNN_name>/main.ts
    demos/<NNN_name>/README.md

Run tools/verify_demos.sh afterwards: a demo only counts if the emitted SA-ASM
actually assembles.

The corpus deliberately stays inside the lowerer's verified subset (see
REQUIREMENTS.md "Known Gaps"): no interpolated templates, no try/catch, no
console.log, no async/wasm/wit. Constructs the lowerer refuses are represented
only where a demo is specifically about the refusal.
"""
import os
import textwrap

HERE = os.path.dirname(os.path.abspath(__file__))
DEMOS = os.path.normpath(os.path.join(HERE, os.pardir, "demos"))

# (dir, title, blurb, source)
D = []


def d(name, title, blurb, src):
    D.append((name, title, blurb, textwrap.dedent(src).strip() + "\n"))


# ---------------------------------------------------------------- basics
d("001_hello_world", "Hello World", "Smallest useful lowering: a typed function with a return value.",
  """
  function main(): i32 {
    const msg: string = `hello world`;
    return 0;
  }
  """)

d("002_add_two_numbers", "Add Two Numbers", "Scalar arithmetic on i32 parameters.",
  """
  function add(a: i32, b: i32): i32 {
    return a + b;
  }
  function main(): i32 {
    return add(2, 3);
  }
  """)

d("003_subtraction", "Subtraction", "Binary minus, including a negative-result expression.",
  """
  function sub(a: i32, b: i32): i32 {
    return a - b;
  }
  function main(): i32 {
    const r: i32 = sub(10, 4);
    return r;
  }
  """)

d("004_multiplication", "Multiplication", "Binary multiply.",
  """
  function mul(a: i32, b: i32): i32 {
    return a * b;
  }
  function main(): i32 {
    return mul(6, 7);
  }
  """)

d("005_division", "Division", "Integer division.",
  """
  function div(a: i32, b: i32): i32 {
    return a / b;
  }
  function main(): i32 {
    return div(84, 2);
  }
  """)

d("006_modulo", "Modulo", "Remainder operator.",
  """
  function rem(a: i32, b: i32): i32 {
    return a % b;
  }
  function main(): i32 {
    return rem(17, 5);
  }
  """)

d("007_operator_precedence", "Operator Precedence", "Mixed arithmetic in one expression.",
  """
  function main(): i32 {
    const v: i32 = 2 + 3 * 4 - 6 / 2;
    return v;
  }
  """)

d("008_unary_minus", "Unary Minus", "Negation via subtraction from zero.",
  """
  function negate(x: i32): i32 {
    return 0 - x;
  }
  function main(): i32 {
    return negate(7);
  }
  """)

d("009_nested_arithmetic", "Nested Arithmetic", "Arithmetic split across statements.",
  """
  function main(): i32 {
    let a: i32 = 3;
    let b: i32 = 4;
    let c: i32 = a * b;
    let d: i32 = c + a;
    return d;
  }
  """)

d("010_reassign_scalar", "Reassign Scalar", "A `let` binding written more than once.",
  """
  function main(): i32 {
    let x: i32 = 1;
    x = 2;
    x = x + 3;
    return x;
  }
  """)

d("011_less_than", "Less Than", "Comparison producing a branch condition.",
  """
  function is_small(x: i32): i32 {
    if (x < 10) { return 1; }
    return 0;
  }
  function main(): i32 {
    return is_small(4);
  }
  """)

d("012_less_equal", "Less Or Equal", "Inclusive lower-bound comparison.",
  """
  function at_least(x: i32, n: i32): i32 {
    if (x <= n) { return 1; }
    return 0;
  }
  function main(): i32 {
    return at_least(5, 5);
  }
  """)

d("013_greater_than", "Greater Than", "Strict upper-bound comparison.",
  """
  function above(x: i32, n: i32): i32 {
    if (x > n) { return 1; }
    return 0;
  }
  function main(): i32 {
    return above(9, 5);
  }
  """)

d("014_greater_equal", "Greater Or Equal", "Inclusive upper-bound comparison.",
  """
  function at_most(x: i32, n: i32): i32 {
    if (x >= n) { return 1; }
    return 0;
  }
  function main(): i32 {
    return at_most(5, 5);
  }
  """)

d("015_equality", "Equality", "`==` comparison.",
  """
  function same(a: i32, b: i32): i32 {
    if (a == b) { return 1; }
    return 0;
  }
  function main(): i32 {
    return same(4, 4);
  }
  """)

d("016_inequality", "Inequality", "`!=` comparison.",
  """
  function different(a: i32, b: i32): i32 {
    if (a != b) { return 1; }
    return 0;
  }
  function main(): i32 {
    return different(4, 5);
  }
  """)

d("017_logical_and", "Logical And", "`&&` short-circuit condition.",
  """
  function in_range(x: i32, lo: i32, hi: i32): i32 {
    if (x >= lo && x <= hi) { return 1; }
    return 0;
  }
  function main(): i32 {
    return in_range(5, 0, 10);
  }
  """)

d("018_logical_or", "Logical Or", "`||` short-circuit condition.",
  """
  function out_of_range(x: i32, lo: i32, hi: i32): i32 {
    if (x < lo || x > hi) { return 1; }
    return 0;
  }
  function main(): i32 {
    return out_of_range(50, 0, 10);
  }
  """)

d("019_negated_condition", "Negated Condition", "`!` on a boolean expression.",
  """
  function main(): i32 {
    const ready: i32 = 0;
    if (!ready) { return 1; }
    return 0;
  }
  """)

d("020_constant_booleans", "Boolean Literals", "`true`/`false` folded to integers.",
  """
  function main(): i32 {
    const yes: i32 = 1;
    const no: i32 = 0;
    if (yes) { return 1; }
    return no;
  }
  """)

# ------------------------------------------------------------ control flow
d("021_if_then", "If Then", "Conditional without an else arm.",
  """
  function classify(x: i32): i32 {
    let r: i32 = 0;
    if (x > 0) { r = 1; }
    return r;
  }
  function main(): i32 {
    return classify(3);
  }
  """)

d("022_if_else", "If Else", "Two-armed conditional returning from both arms.",
  """
  function sign(x: i32): i32 {
    if (x < 0) { return 0 - 1; } else { return 1; }
  }
  function main(): i32 {
    return sign(0 - 5);
  }
  """)

d("023_if_else_max", "If Else Max", "Branch selection returning the larger operand.",
  """
  function max(a: i32, b: i32): i32 {
    if (a > b) { return a; } else { return b; }
  }
  function main(): i32 {
    return max(10, 20);
  }
  """)

d("024_if_else_min", "If Else Min", "Branch selection returning the smaller operand.",
  """
  function min(a: i32, b: i32): i32 {
    if (a < b) { return a; } else { return b; }
  }
  function main(): i32 {
    return min(10, 20);
  }
  """)

d("025_if_else_if_chain", "If Else If Chain", "Multi-way selection by narrowing ranges.",
  """
  function bucket(x: i32): i32 {
    if (x < 0) { return 0 - 1; }
    else if (x == 0) { return 0; }
    else if (x < 10) { return 1; }
    else { return 2; }
  }
  function main(): i32 {
    return bucket(5);
  }
  """)

d("026_nested_if", "Nested If", "An if inside an if.",
  """
  function main(): i32 {
    let r: i32 = 0;
    if (1 < 2) {
      if (2 < 3) { r = 1; }
    }
    return r;
  }
  """)

d("027_if_with_assignment", "If With Assignment", "Both arms writing a local.",
  """
  function pick(flag: i32): i32 {
    let r: i32 = 0;
    if (flag) { r = 7; } else { r = 9; }
    return r;
  }
  function main(): i32 {
    return pick(1);
  }
  """)

d("028_guard_style_if", "Guard Style If", "Early return used as a guard clause.",
  """
  function checked(x: i32): i32 {
    if (x < 0) { return 0; }
    return x * 2;
  }
  function main(): i32 {
    return checked(21);
  }
  """)

d("029_double_guard", "Double Guard", "Two sequential guard clauses.",
  """
  function checked(a: i32, b: i32): i32 {
    if (a < 0) { return 0; }
    if (b < 0) { return 0; }
    return a + b;
  }
  function main(): i32 {
    return checked(3, 4);
  }
  """)

d("030_early_return_in_if", "Early Return In If", "Return inside the then arm, code after the if.",
  """
  function f(x: i32): i32 {
    if (x > 0) { return 1; }
    return 2;
  }
  function main(): i32 {
    return f(1);
  }
  """)

d("031_both_arms_return", "Both Arms Return", "Both arms return, so the merge block is unreachable.",
  """
  function g(x: i32): i32 {
    if (x > 0) { return 1; } else { return 2; }
  }
  function main(): i32 {
    return g(1);
  }
  """)

d("032_both_arms_return_trailing", "Both Arms Return Trailing", "Both arms return and a trailing statement follows.",
  """
  function g(x: i32): i32 {
    if (x > 0) { return 1; } else { return 2; }
    return 3;
  }
  function main(): i32 {
    return g(1);
  }
  """)

d("033_nested_early_returns", "Nested Early Returns", "Early returns from nested conditionals.",
  """
  function h(x: i32): i32 {
    if (x > 0) {
      if (x > 5) { return 2; }
      return 1;
    }
    return 0;
  }
  function main(): i32 {
    return h(9);
  }
  """)

d("034_triple_nested_if", "Triple Nested If", "Three levels of nesting.",
  """
  function main(): i32 {
    let r: i32 = 0;
    if (1 < 2) {
      if (2 < 3) {
        if (3 < 4) { r = 1; }
      }
    }
    return r;
  }
  """)

d("035_if_no_brace_statement", "If Without Braces", "Single-statement arms without braces.",
  """
  function main(): i32 {
    let r: i32 = 0;
    if (1 < 2) r = 5;
    return r;
  }
  """)

d("036_if_comparison_chain", "If Comparison Chain", "Chained comparisons in one condition.",
  """
  function between(x: i32): i32 {
    if (0 < x && x < 100) { return 1; }
    return 0;
  }
  function main(): i32 {
    return between(50);
  }
  """)

d("037_if_mutual_exclusive", "If Mutually Exclusive", "Two ifs where only one can fire.",
  """
  function classify(x: i32): i32 {
    let r: i32 = 0;
    if (x == 1) { r = 10; }
    if (x == 2) { r = 20; }
    return r;
  }
  function main(): i32 {
    return classify(2);
  }
  """)

d("038_if_accumulate", "If Accumulate", "Conditional accumulation across a loop body.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) {
      if (i % 2 == 0) { t = t + i; }
    }
    return t;
  }
  """)

d("039_deep_else_nesting", "Deep Else Nesting", "Deeply nested else arms.",
  """
  function deep(x: i32): i32 {
    if (x == 1) {
      return 100;
    } else {
      if (x == 2) {
        return 200;
      } else {
        if (x == 3) { return 300; } else { return 0; }
      }
    }
  }
  function main(): i32 {
    return deep(2);
  }
  """)

d("040_boolean_aggregation", "Boolean Aggregation", "A flag aggregated from several comparisons.",
  """
  function main(): i32 {
    const a: i32 = 5;
    const b: i32 = 5;
    const same: i32 = a == b;
    if (same && a > 0) { return 1; }
    return 0;
  }
  """)

# ------------------------------------------------------------------ loops
d("041_while_loop", "While Loop", "Counting loop with a while.",
  """
  function sum_to(n: i32): i32 {
    let total: i32 = 0;
    let i: i32 = 0;
    while (i < n) {
      total = total + i;
      i = i + 1;
    }
    return total;
  }
  function main(): i32 {
    return sum_to(5);
  }
  """)

d("042_while_decrement", "While Decrement", "Countdown loop.",
  """
  function main(): i32 {
    let n: i32 = 5;
    let acc: i32 = 1;
    while (n > 0) {
      acc = acc * n;
      n = n - 1;
    }
    return acc;
  }
  """)

d("043_while_never_runs", "While Never Runs", "Loop whose condition is false on entry.",
  """
  function main(): i32 {
    let i: i32 = 0;
    let t: i32 = 0;
    while (i < 0) { t = t + 1; }
    return t;
  }
  """)

d("044_while_break", "While Break", "Early exit from a while loop.",
  """
  function main(): i32 {
    let i: i32 = 0;
    let t: i32 = 0;
    while (i < 100) {
      if (i == 3) { break; }
      t = t + i;
      i = i + 1;
    }
    return t;
  }
  """)

d("045_while_early_return", "While Early Return", "Return from inside a loop body.",
  """
  function find(n: i32): i32 {
    let i: i32 = 0;
    while (i < n) {
      if (i == 2) { return 42; }
      i = i + 1;
    }
    return 0;
  }
  function main(): i32 {
    return find(10);
  }
  """)

d("046_c_for_loop", "C-Style For", "Three-clause for loop.",
  """
  function main(): i32 {
    let total: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) { total = total + i; }
    return total;
  }
  """)

d("047_c_for_step_two", "C-Style For Step Two", "For loop with a stride of two.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i = i + 2) { t = t + i; }
    return t;
  }
  """)

d("048_c_for_downward", "C-Style For Downward", "For loop counting down.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 5; i > 0; i = i - 1) { t = t + i; }
    return t;
  }
  """)

d("049_c_for_nested", "C-Style For Nested", "Nested for loops.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) {
      for (let j: i32 = 0; j < 3; j++) { t = t + 1; }
    }
    return t;
  }
  """)

d("050_c_for_with_if", "C-Style For With If", "For loop whose body branches.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i++) {
      if (i % 2 == 0) { t = t + i; } else { t = t + 0; }
    }
    return t;
  }
  """)

d("051_c_for_break", "C-Style For Break", "Break out of a for loop.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i++) {
      if (i == 4) { break; }
      t = t + i;
    }
    return t;
  }
  """)

d("052_for_of_array", "For Of Array", "Iterate an array literal with for-of.",
  """
  function main(): i32 {
    const arr: i32[] = [1, 2, 3];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("053_for_of_untyped", "For Of Untyped", "for-of over an untyped array literal.",
  """
  function main(): i32 {
    let arr = [1, 2, 3];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("054_for_of_empty", "For Of Empty", "for-of over an empty array.",
  """
  function main(): i32 {
    const arr: i32[] = [];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("055_for_of_single", "For Of Single", "for-of over a one-element array.",
  """
  function main(): i32 {
    const arr: i32[] = [42];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("056_nested_loops", "Nested Loops", "A for inside a while.",
  """
  function main(): i32 {
    let t: i32 = 0;
    let i: i32 = 0;
    while (i < 3) {
      for (let j: i32 = 0; j < 3; j++) { t = t + 1; }
      i = i + 1;
    }
    return t;
  }
  """)

d("057_loop_accumulate_product", "Loop Accumulate Product", "Factorial by loop.",
  """
  function factorial(n: i32): i32 {
    let acc: i32 = 1;
    for (let i: i32 = 1; i <= n; i++) { acc = acc * i; }
    return acc;
  }
  function main(): i32 {
    return factorial(5);
  }
  """)

d("058_loop_sum_even", "Loop Sum Even", "Sum the even values in a range.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i++) {
      if (i % 2 == 0) { t = t + i; }
    }
    return t;
  }
  """)

d("059_loop_count_down_acc", "Loop Count Down Accumulator", "Accumulator driven by a countdown.",
  """
  function main(): i32 {
    let n: i32 = 5;
    let t: i32 = 0;
    while (n > 0) {
      t = t + n;
      n = n - 1;
    }
    return t;
  }
  """)

d("060_loop_with_switch", "Loop With Switch", "Switch inside a loop body.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) {
      switch (i) {
        case 0: { t = t + 1; break; }
        case 1: { t = t + 10; break; }
        default: { t = t + 100; }
      }
    }
    return t;
  }
  """)

d("061_loop_max_scan", "Loop Max Scan", "Scan for the maximum with an if guard.",
  """
  function main(): i32 {
    let best: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) {
      if (i > best) { best = i; }
    }
    return best;
  }
  """)

d("062_loop_min_scan", "Loop Min Scan", "Scan for the minimum with an if guard.",
  """
  function main(): i32 {
    let worst: i32 = 100;
    for (let i: i32 = 0; i < 5; i++) {
      if (i < worst) { worst = i; }
    }
    return worst;
  }
  """)

d("063_loop_string_count", "Loop String Count", "Loop with a string local alongside counters.",
  """
  function main(): i32 {
    const label: string = `counting`;
    let t: i32 = 0;
    for (let i: i32 = 0; i < 4; i++) { t = t + i; }
    return t;
  }
  """)

d("064_loop_in_function_param", "Loop With Function Parameter", "Loop bounded by a parameter.",
  """
  function count_upto(n: i32): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < n; i++) { t = t + 1; }
    return t;
  }
  function main(): i32 {
    return count_upto(7);
  }
  """)

d("065_loop_two_bounds", "Loop Two Bounds", "Loop with independent lower and upper bounds.",
  """
  function main(): i32 {
    const lo: i32 = 2;
    const hi: i32 = 8;
    let t: i32 = 0;
    for (let i: i32 = lo; i < hi; i++) { t = t + i; }
    return t;
  }
  """)

d("066_break_in_nested_if", "Break In Nested If", "Break guarded by a nested if.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i++) {
      if (i > 1) { if (i > 5) { break; } }
      t = t + i;
    }
    return t;
  }
  """)

d("067_loop_body_declaration", "Loop Body Declaration", "A local declared inside a loop body.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) {
      const doubled: i32 = i * 2;
      t = t + doubled;
    }
    return t;
  }
  """)

d("068_loop_reuse_variable", "Loop Reuse Variable", "A variable carried across iterations.",
  """
  function main(): i32 {
    let carry: i32 = 0;
    for (let i: i32 = 0; i < 4; i++) { carry = carry + i; }
    return carry;
  }
  """)

d("069_while_with_compound_cond", "While Compound Condition", "Two-term loop condition.",
  """
  function main(): i32 {
    let i: i32 = 0;
    let t: i32 = 10;
    while (i < 5 && t > 0) {
      t = t - 1;
      i = i + 1;
    }
    return t;
  }
  """)

d("070_for_of_in_function", "For Of In Function", "for-of over a parameter-supplied count.",
  """
  function total_of(n: i32): i32 {
    const arr: i32[] = [1, 2, 3, 4];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t + n;
  }
  function main(): i32 {
    return total_of(1);
  }
  """)

# ----------------------------------------------------------------- switch
d("071_switch_basic", "Switch Basic", "Two cases with a default.",
  """
  function pick(a: i32): i32 {
    let r: i32 = 0;
    switch (a) {
      case 1: { r = 10; break; }
      case 2: { r = 20; break; }
      default: { r = 99; }
    }
    return r;
  }
  function main(): i32 {
    return pick(1);
  }
  """)

d("072_switch_no_default", "Switch No Default", "Cases with no default arm.",
  """
  function pick(a: i32): i32 {
    let r: i32 = 0;
    switch (a) {
      case 1: { r = 10; break; }
      case 2: { r = 20; break; }
    }
    return r;
  }
  function main(): i32 {
    return pick(1);
  }
  """)

d("073_switch_unbraced_cases", "Switch Unbraced Cases", "Case bodies without braces.",
  """
  function pick(a: i32): i32 {
    let r: i32 = 0;
    switch (a) {
      case 1: r = 10; break;
      default: r = 99;
    }
    return r;
  }
  function main(): i32 {
    return pick(2);
  }
  """)

d("074_switch_default_only", "Switch Default Only", "A switch with only a default arm.",
  """
  function pick(a: i32): i32 {
    let r: i32 = 0;
    switch (a) {
      default: { r = 7; }
    }
    return r;
  }
  function main(): i32 {
    return pick(0);
  }
  """)

d("075_switch_many_cases", "Switch Many Cases", "Five-way dispatch.",
  """
  function name_of(c: i32): i32 {
    let r: i32 = 0;
    switch (c) {
      case 0: { r = 100; break; }
      case 1: { r = 200; break; }
      case 2: { r = 300; break; }
      case 3: { r = 400; break; }
      default: { r = 999; }
    }
    return r;
  }
  function main(): i32 {
    return name_of(2);
  }
  """)

d("076_switch_with_return", "Switch With Return", "Return from inside each case.",
  """
  function d(a: i32): i32 {
    switch (a) {
      case 1: { return 10; }
      case 2: { return 20; }
      default: { return 0; }
    }
  }
  function main(): i32 {
    return d(1);
  }
  """)

d("077_switch_fallthrough_default", "Switch Default Fallthrough", "Default body falls to the merge point.",
  """
  function pick(a: i32): i32 {
    let r: i32 = 0;
    switch (a) {
      case 1: { r = 10; break; }
      default: { r = 5; }
    }
    return r;
  }
  function main(): i32 {
    return pick(3);
  }
  """)

d("078_switch_on_expression", "Switch On Expression", "Switch over a computed value.",
  """
  function classify(n: i32): i32 {
    const bucket: i32 = n % 3;
    let r: i32 = 0;
    switch (bucket) {
      case 0: { r = 100; break; }
      case 1: { r = 200; break; }
      default: { r = 300; }
    }
    return r;
  }
  function main(): i32 {
    return classify(7);
  }
  """)

d("079_switch_nested", "Switch Nested", "Switch inside a switch.",
  """
  function main(): i32 {
    let t: i32 = 0;
    switch (1) {
      case 1: {
        switch (2) {
          case 2: { t = 5; break; }
          default: { t = 6; }
        }
        break;
      }
      default: { t = 0; }
    }
    return t;
  }
  """)

d("080_switch_in_loop_break", "Switch In Loop", "Switch guarding a loop break.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) {
      switch (i) {
        case 3: { t = 99; break; }
        default: { t = t + i; }
      }
      t = t + 100;
    }
    return t;
  }
  """)

# -------------------------------------------------------------- functions
d("081_no_params_no_ret", "No Params No Return", "Void function with no parameters.",
  """
  function noop() {
    let scratch: i32 = 1;
  }
  function main() {
    noop();
  }
  """)

d("082_single_param", "Single Parameter", "One parameter, returned doubled.",
  """
  function double(x: i32): i32 {
    return x * 2;
  }
  function main(): i32 {
    return double(21);
  }
  """)

d("083_many_params", "Many Parameters", "Six-parameter function.",
  """
  function add6(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32): i32 {
    return a + b + c + d + e + f;
  }
  function main(): i32 {
    return add6(1, 2, 3, 4, 5, 6);
  }
  """)

d("084_void_function", "Void Function", "Void function with a parameter.",
  """
  function logIt(x: i32) {
    let y: i32 = x;
  }
  function main() {
    logIt(5);
  }
  """)

d("085_function_call_chain", "Function Call Chain", "Calls composed into an expression.",
  """
  function a(x: i32): i32 { return x + 1; }
  function b(x: i32): i32 { return a(x) * 2; }
  function c(x: i32): i32 { return b(x) + a(x); }
  function main(): i32 {
    return c(3);
  }
  """)

d("086_recursion_factorial", "Recursion Factorial", "Recursive factorial.",
  """
  function fact(n: i32): i32 {
    if (n <= 1) { return 1; }
    return n * fact(n - 1);
  }
  function main(): i32 {
    return fact(5);
  }
  """)

d("087_recursion_fibonacci", "Recursion Fibonacci", "Naive recursive Fibonacci.",
  """
  function fib(n: i32): i32 {
    if (n < 2) { return n; }
    return fib(n - 1) + fib(n - 2);
  }
  function main(): i32 {
    return fib(10);
  }
  """)

d("088_recursion_guarded", "Recursion Guarded", "Recursion with an explicit base case.",
  """
  function countdown(n: i32): i32 {
    if (n <= 0) { return 0; }
    return 1 + countdown(n - 1);
  }
  function main(): i32 {
    return countdown(5);
  }
  """)

d("089_helper_functions", "Helper Functions", "Several small helpers composed.",
  """
  function double(x: i32): i32 { return x * 2; }
  function triple(x: i32): i32 { return x * 3; }
  function sum_dbl_tri(x: i32): i32 { return double(x) + triple(x); }
  function main(): i32 {
    return sum_dbl_tri(4);
  }
  """)

d("090_function_in_expression", "Function In Expression", "A call used inside an arithmetic expression.",
  """
  function inc(x: i32): i32 { return x + 1; }
  function main(): i32 {
    return inc(1) + inc(2) * inc(3);
  }
  """)

d("091_many_functions", "Many Functions", "Many small functions in one file.",
  """
  function f0(x: i32): i32 { return x + 0; }
  function f1(x: i32): i32 { return x + 1; }
  function f2(x: i32): i32 { return x + 2; }
  function f3(x: i32): i32 { return x + 3; }
  function main(): i32 {
    return f0(1) + f1(1) + f2(1) + f3(1);
  }
  """)

d("092_call_with_expressions", "Call With Expressions", "Call arguments that are expressions.",
  """
  function clamp(x: i32, lo: i32, hi: i32): i32 {
    if (x < lo) { return lo; }
    if (x > hi) { return hi; }
    return x;
  }
  function main(): i32 {
    return clamp(3 * 4, 0 + 1, 10 + 2);
  }
  """)

d("093_nested_calls", "Nested Calls", "Call whose argument is itself a call.",
  """
  function add(a: i32, b: i32): i32 { return a + b; }
  function main(): i32 {
    return add(add(1, 2), add(3, 4));
  }
  """)

d("094_param_used_twice", "Parameter Used Twice", "A parameter read on both sides of a comparison.",
  """
  function in_pair(x: i32): i32 {
    if (x > 0 && x < 100) { return 1; }
    return 0;
  }
  function main(): i32 {
    return in_pair(50);
  }
  """)

d("095_param_shadow_local", "Parameter Shadowed By Local", "A local reusing a parameter's value.",
  """
  function widen(x: i32): i32 {
    let y: i32 = x;
    let z: i32 = y + 1;
    return z;
  }
  function main(): i32 {
    return widen(9);
  }
  """)

d("096_return_immediately", "Return Immediately", "Function whose body is a single return.",
  """
  function identity(x: i32): i32 {
    return x;
  }
  function main(): i32 {
    return identity(7);
  }
  """)

d("097_multiple_call_sites", "Multiple Call Sites", "One function called from two places.",
  """
  function half(x: i32): i32 { return x / 2; }
  function main(): i32 {
    const a: i32 = half(10);
    const b: i32 = half(20);
    return a + b;
  }
  """)

d("098_composed_predicates", "Composed Predicates", "Predicates composed into a decision function.",
  """
  function is_even(x: i32): i32 { if (x % 2 == 0) { return 1; } return 0; }
  function is_positive(x: i32): i32 { if (x > 0) { return 1; } return 0; }
  function main(): i32 {
    const v: i32 = 4;
    if (is_even(v) && is_positive(v)) { return 1; }
    return 0;
  }
  """)

d("099_default_void_main", "Default Void Main", "Entry point with no return type.",
  """
  function helper(x: i32): i32 { return x + 1; }
  function main() {
    const r: i32 = helper(1);
  }
  """)

d("100_deep_expression", "Deep Expression", "Long chained arithmetic expression.",
  """
  function main(): i32 {
    return 1 + 2 * 3 - 4 / 2 + 5 % 3 - 6 + 7 * 2;
  }
  """)

# ----------------------------------------------------------------- arrays
d("101_array_literal_typed", "Array Literal Typed", "Typed i32 array declaration.",
  """
  function main(): i32 {
    const arr: i32[] = [10, 20, 30];
    return arr[0];
  }
  """)

d("102_array_literal_untyped", "Array Literal Untyped", "Inferred array declaration.",
  """
  function main(): i32 {
    let arr = [1, 2, 3];
    return arr[1];
  }
  """)

d("103_array_index_read", "Array Index Read", "Reading several elements.",
  """
  function main(): i32 {
    const arr: i32[] = [1, 2, 3, 4];
    const a: i32 = arr[0];
    const b: i32 = arr[3];
    return a + b;
  }
  """)

d("104_array_index_write", "Array Index Write", "Writing to an element then reading it.",
  """
  function main(): i32 {
    let arr: i32[] = [1, 2, 3];
    arr[1] = 99;
    return arr[1];
  }
  """)

d("105_array_single_element", "Array Single Element", "One-element array.",
  """
  function main(): i32 {
    const arr: i32[] = [7];
    return arr[0];
  }
  """)

d("106_array_empty", "Array Empty", "Empty array literal.",
  """
  function main(): i32 {
    const arr: i32[] = [];
    return 0;
  }
  """)

d("107_array_large", "Array Large", "Longer array literal.",
  """
  function main(): i32 {
    const arr: i32[] = [1, 2, 3, 4, 5, 6, 7, 8];
    return arr[7];
  }
  """)

d("108_array_sum_loop", "Array Sum Loop", "Summing an array with for-of.",
  """
  function sum(arr_len: i32): i32 {
    const arr: i32[] = [1, 2, 3, 4, 5];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t + arr_len;
  }
  function main(): i32 {
    return sum(0);
  }
  """)

d("109_array_write_then_loop", "Array Write Then Loop", "Mutate then iterate.",
  """
  function main(): i32 {
    let arr: i32[] = [1, 2, 3];
    arr[0] = 10;
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("110_array_index_expression", "Array Index Expression", "Computed index expression.",
  """
  function main(): i32 {
    const arr: i32[] = [5, 6, 7, 8];
    const i: i32 = 1 + 1;
    return arr[i];
  }
  """)

d("111_array_in_function", "Array In Function", "Array local inside a function.",
  """
  function first(): i32 {
    const arr: i32[] = [11, 22];
    return arr[0];
  }
  function main(): i32 {
    return first();
  }
  """)

d("112_array_and_struct", "Array And Struct", "Array alongside a struct-typed local.",
  """
  interface Point { x: i32; y: i32; }
  function main(): i32 {
    const arr: i32[] = [1, 2];
    const p: Point = { x: 3, y: 4 };
    return arr[0] + p.x;
  }
  """)

d("113_array_reexport_write", "Array Repeated Writes", "Several writes to different indices.",
  """
  function main(): i32 {
    let arr: i32[] = [0, 0, 0];
    arr[0] = 1;
    arr[1] = 2;
    arr[2] = 3;
    return arr[2];
  }
  """)

d("114_array_of_strings", "Array Of Strings", "String-typed array literal.",
  """
  function main(): i32 {
    const names: string[] = [`a`, `b`];
    return 0;
  }
  """)

d("115_array_with_enum", "Array With Enum", "Enum-typed local alongside an array.",
  """
  enum Color { Red, Green, Blue }
  function main(): i32 {
    const arr: i32[] = [1, 2];
    const c: i32 = 0;
    return arr[0] + c;
  }
  """)

d("116_array_loop_break", "Array Loop Break", "Breaking out of a for-of loop.",
  """
  function main(): i32 {
    const arr: i32[] = [1, 2, 3, 4];
    let t: i32 = 0;
    for (const v of arr) {
      if (v == 3) { break; }
      t = t + v;
    }
    return t;
  }
  """)

d("117_array_nested_loops", "Array Nested Loops", "Two for-of loops in sequence.",
  """
  function main(): i32 {
    const a: i32[] = [1, 2];
    const b: i32[] = [3, 4];
    let t: i32 = 0;
    for (const x of a) { t = t + x; }
    for (const y of b) { t = t + y; }
    return t;
  }
  """)

d("118_array_as_param_like", "Array Local As Argument", "Array local passed to a helper.",
  """
  function total(n: i32): i32 { return n * 2; }
  function main(): i32 {
    const arr: i32[] = [1, 2, 3];
    return total(arr[2]);
  }
  """)

d("119_array_longer_literal", "Array Longer Literal", "Ten-element array.",
  """
  function main(): i32 {
    const arr: i32[] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    return arr[9];
  }
  """)

d("120_array_accumulate_index", "Array Accumulate By Index", "Index-driven accumulation over an array.",
  """
  function main(): i32 {
    const arr: i32[] = [1, 2, 3, 4];
    let t: i32 = 0;
    for (let i: i32 = 0; i < 4; i++) { t = t + arr[i]; }
    return t;
  }
  """)

# ---------------------------------------------------------------- structs
d("121_struct_literal", "Struct Literal", "Interface used as a struct type.",
  """
  interface Point { x: i32; y: i32; }
  function main(): i32 {
    const p: Point = { x: 3, y: 4 };
    return p.x;
  }
  """)

d("122_struct_field_read", "Struct Field Read", "Reading both fields.",
  """
  interface Point { x: i32; y: i32; }
  function sum(p: Point): i32 {
    return p.x + p.y;
  }
  function main(): i32 {
    const p: Point = { x: 10, y: 20 };
    return sum(p);
  }
  """)

d("123_struct_field_write", "Struct Field Write", "Assigning to a field after construction.",
  """
  interface Point { x: i32; y: i32; }
  function main(): i32 {
    const p: Point = { x: 1, y: 2 };
    p.x = 100;
    return p.x;
  }
  """)

d("124_struct_three_fields", "Struct Three Fields", "Three-field struct layout.",
  """
  interface V3 { x: i32; y: i32; z: i32; }
  function main(): i32 {
    const v: V3 = { x: 1, y: 2, z: 3 };
    return v.z;
  }
  """)

d("125_struct_nested", "Struct Nested", "Struct-typed field holding another struct.",
  """
  interface Inner { a: i32; b: i32; }
  interface Outer { inner: Inner; tag: i32; }
  function main(): i32 {
    const o: Outer = { inner: { a: 1, b: 2 }, tag: 3 };
    return o.tag;
  }
  """)

d("126_struct_in_function_param", "Struct As Parameter", "Struct passed to a function.",
  """
  interface Point { x: i32; y: i32; }
  function getX(p: Point): i32 {
    return p.x;
  }
  function main(): i32 {
    const p: Point = { x: 7, y: 8 };
    return getX(p);
  }
  """)

d("127_struct_created_by_function", "Struct Created By Function", "Factory function returning a struct.",
  """
  interface Point { x: i32; y: i32; }
  function make(x: i32, y: i32): Point {
    const p: Point = { x: x, y: y };
    return p;
  }
  function main(): i32 {
    const p: Point = make(4, 5);
    return p.y;
  }
  """)

d("128_struct_four_fields", "Struct Four Fields", "Four-field struct with a read and a write.",
  """
  interface Rect { x: i32; y: i32; w: i32; h: i32; }
  function main(): i32 {
    const r: Rect = { x: 0, y: 0, w: 4, h: 5 };
    r.h = 10;
    return r.h;
  }
  """)

d("129_struct_with_string", "Struct With String Field", "Struct mixing a pointer and an integer.",
  """
  interface Named { name: string; id: i32; }
  function main(): i32 {
    const n: Named = { name: `widget`, id: 7 };
    return n.id;
  }
  """)

d("130_struct_field_in_loop", "Struct Field In Loop", "Struct field read inside a loop.",
  """
  interface Point { x: i32; y: i32; }
  function main(): i32 {
    const p: Point = { x: 2, y: 3 };
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) { t = t + p.x; }
    return t;
  }
  """)

d("131_struct_field_in_if", "Struct Field In If", "Struct field used as a condition.",
  """
  interface Limit { max: i32; }
  function main(): i32 {
    const l: Limit = { max: 10 };
    if (l.max > 5) { return 1; }
    return 0;
  }
  """)

d("132_two_structs", "Two Struct Types", "Two distinct interfaces in one file.",
  """
  interface Point { x: i32; y: i32; }
  interface Size { w: i32; h: i32; }
  function main(): i32 {
    const p: Point = { x: 1, y: 2 };
    const s: Size = { w: 3, h: 4 };
    return p.x + s.w;
  }
  """)

d("133_struct_local_reassign", "Struct Local Reassigned", "Rebinding a struct-typed local.",
  """
  interface Point { x: i32; y: i32; }
  function main(): i32 {
    let p: Point = { x: 1, y: 1 };
    p = { x: 2, y: 2 };
    return p.x;
  }
  """)

d("134_struct_field_sum_all", "Struct Field Sum All", "Summing every field of a struct.",
  """
  interface V3 { x: i32; y: i32; z: i32; }
  function total(v: V3): i32 {
    return v.x + v.y + v.z;
  }
  function main(): i32 {
    const v: V3 = { x: 1, y: 2, z: 3 };
    return total(v);
  }
  """)

d("135_struct_bool_field", "Struct Boolean Field", "Struct whose field is used as a flag.",
  """
  interface Flags { ready: i32; count: i32; }
  function main(): i32 {
    const f: Flags = { ready: 1, count: 4 };
    let r: i32 = 0;
    if (f.ready) { r = f.count; }
    return r;
  }
  """)

d("136_struct_array_field", "Struct With Array Field", "Struct and array locals combined.",
  """
  interface Bag { size: i32; }
  function main(): i32 {
    const arr: i32[] = [1, 2, 3];
    const b: Bag = { size: 3 };
    return arr[0] + b.size;
  }
  """)

d("137_struct_chain_call", "Struct Field Into Call", "A struct field used as a call argument.",
  """
  interface Point { x: i32; y: i32; }
  function twice(x: i32): i32 { return x * 2; }
  function main(): i32 {
    const p: Point = { x: 5, y: 6 };
    return twice(p.x);
  }
  """)

d("138_struct_field_in_switch", "Struct Field In Switch", "Switching on a struct field.",
  """
  interface State { code: i32; }
  function main(): i32 {
    const s: State = { code: 2 };
    let r: i32 = 0;
    switch (s.code) {
      case 1: { r = 10; break; }
      case 2: { r = 20; break; }
      default: { r = 0; }
    }
    return r;
  }
  """)

d("139_struct_generic_name", "Struct Generic Name", "Interface with a generic parameter.",
  """
  interface Box<T> { value: T; }
  function main(): i32 {
    const b: Box = { value: 5 };
    return b.value;
  }
  """)

d("140_struct_deep_field", "Struct Deep Field Access", "Reading a field of a nested struct.",
  """
  interface Inner { a: i32; b: i32; }
  interface Outer { inner: Inner; tag: i32; }
  function main(): i32 {
    const o: Outer = { inner: { a: 9, b: 8 }, tag: 1 };
    return o.inner.a;
  }
  """)

# ------------------------------------------------------------------ enums
d("141_enum_basic", "Enum Basic", "Enum with auto-numbered variants.",
  """
  enum Color { Red, Green, Blue }
  function main(): i32 {
    const c: i32 = 0;
    return c;
  }
  """)

d("142_enum_used_in_switch", "Enum Used In Switch", "Switch over an enum value.",
  """
  enum Color { Red, Green, Blue }
  function classify(c: i32): i32 {
    let r: i32 = 0;
    switch (c) {
      case 0: { r = 10; break; }
      case 1: { r = 20; break; }
      default: { r = 30; }
    }
    return r;
  }
  function main(): i32 {
    return classify(1);
  }
  """)

d("143_enum_in_struct", "Enum In Struct", "Enum alongside a struct local.",
  """
  enum State { Idle, Busy }
  interface Ctx { state: i32; id: i32; }
  function main(): i32 {
    const c: Ctx = { state: 1, id: 2 };
    return c.state;
  }
  """)

d("144_enum_in_array", "Enum In Array", "Enum value stored in an array element.",
  """
  enum State { Idle, Busy }
  function main(): i32 {
    const arr: i32[] = [0, 1];
    return arr[1];
  }
  """)

d("145_enum_three_variants", "Enum Three Variants", "Three-variant enum with a full switch.",
  """
  enum Level { Low, Mid, High }
  function weight(l: i32): i32 {
    let r: i32 = 0;
    switch (l) {
      case 0: { r = 1; break; }
      case 1: { r = 2; break; }
      case 2: { r = 3; break; }
      default: { r = 0; }
    }
    return r;
  }
  function main(): i32 {
    return weight(2);
  }
  """)

d("146_enum_in_function_param", "Enum As Parameter", "Function taking an enum-typed parameter.",
  """
  enum Color { Red, Green }
  function is_red(c: i32): i32 {
    if (c == 0) { return 1; }
    return 0;
  }
  function main(): i32 {
    return is_red(0);
  }
  """)

d("147_enum_in_loop", "Enum In Loop", "Enum value compared inside a loop.",
  """
  enum State { Idle, Busy }
  function main(): i32 {
    const s: i32 = 1;
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) {
      if (s == 1) { t = t + i; }
    }
    return t;
  }
  """)

d("148_enum_returned", "Enum Returned", "Function returning an enum-typed value.",
  """
  enum State { Idle, Busy }
  function next(): i32 {
    return 1;
  }
  function main(): i32 {
    return next();
  }
  """)

d("149_enum_with_array_loop", "Enum With Array Loop", "Enum and a for-of loop together.",
  """
  enum State { Idle, Busy }
  function main(): i32 {
    const arr: i32[] = [0, 1, 0];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("150_enum_nested_if", "Enum In Nested If", "Enum value driving nested conditionals.",
  """
  enum State { Idle, Busy }
  function act(s: i32): i32 {
    if (s == 0) {
      return 1;
    } else {
      if (s == 1) { return 2; } else { return 0; }
    }
  }
  function main(): i32 {
    return act(1);
  }
  """)

# ---------------------------------------------------------------- aliases
d("151_type_alias", "Type Alias", "Type alias declaration.",
  """
  type ID = i64;
  function main(): i32 {
    return 0;
  }
  """)

d("152_alias_scalar", "Alias For Scalar", "Alias naming a scalar type.",
  """
  type Count = i32;
  function main(): i32 {
    const c: Count = 5;
    return c;
  }
  """)

d("153_alias_struct", "Alias For Struct", "Alias naming an interface.",
  """
  interface Point { x: i32; y: i32; }
  type Coord = Point;
  function main(): i32 {
    const p: Point = { x: 1, y: 2 };
    return p.x;
  }
  """)

d("154_generic_annotation", "Generic Annotation", "Generic type in a declaration.",
  """
  function main(): i32 {
    const b: Box<i32> = alloc(4);
    return 0;
  }
  """)

d("155_generic_map", "Generic Map", "Map type parameter list with two arguments.",
  """
  function main(): i32 {
    const m: Map<string, i32> = new Map();
    return 0;
  }
  """)

d("156_generic_local", "Generic Local", "Generic-typed local.",
  """
  function main(): i32 {
    const b: Box<i32> = alloc(4);
    return 0;
  }
  """)

d("157_alias_used_twice", "Alias Used Twice", "Two locals sharing an alias.",
  """
  type Count = i32;
  function main(): i32 {
    const a: Count = 1;
    const b: Count = 2;
    return a + b;
  }
  """)

d("158_alias_with_array", "Alias With Array", "Alias next to an array local.",
  """
  type Count = i32;
  function main(): i32 {
    const arr: i32[] = [1, 2];
    const c: Count = 3;
    return arr[0] + c;
  }
  """)

d("159_alias_with_struct", "Alias With Struct", "Alias and struct locals together.",
  """
  interface Point { x: i32; y: i32; }
  type Coord = i32;
  function main(): i32 {
    const p: Point = { x: 1, y: 2 };
    const c: Coord = 3;
    return p.x + c;
  }
  """)

d("160_alias_in_function", "Alias In Function", "Alias-typed local inside a helper.",
  """
  type Count = i32;
  function bump(c: Count): Count {
    return c + 1;
  }
  function main(): i32 {
    return bump(1);
  }
  """)

# ------------------------------------------------------------- templates
d("161_template_literal", "Template Literal", "Backtick string with no interpolation.",
  """
  function main() {
    const msg: string = `hello`;
  }
  """)

d("162_template_long", "Template Long", "Longer backtick string literal.",
  """
  function main() {
    const msg: string = `a somewhat longer literal string`;
  }
  """)

d("163_template_empty", "Template Empty", "Empty backtick string.",
  """
  function main() {
    const msg: string = ``;
  }
  """)

d("164_template_spaces", "Template With Spaces", "Literal containing spaces.",
  """
  function main() {
    const msg: string = `hello world`;
  }
  """)

d("165_template_in_function", "Template In Function", "String literal inside a helper.",
  """
  function label(): string {
    const s: string = `value`;
    return s;
  }
  function main() {
    label();
  }
  """)

d("166_template_with_code", "Template Alongside Code", "String literal plus arithmetic.",
  """
  function main(): i32 {
    const tag: string = `result`;
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) { t = t + i; }
    return t;
  }
  """)

d("167_string_local_in_loop", "String Local In Loop", "String literal declared beside a loop.",
  """
  function main(): i32 {
    const name: string = `counter`;
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) { t = t + i; }
    return t;
  }
  """)

d("168_string_array", "String Array", "Array of string literals.",
  """
  function main() {
    const words: string[] = [`one`, `two`];
  }
  """)

d("169_string_in_struct", "String In Struct", "String literal in a struct field.",
  """
  interface Named { name: string; id: i32; }
  function main(): i32 {
    const n: Named = { name: `thing`, id: 1 };
    return n.id;
  }
  """)

d("170_string_in_function_call", "String Passed To Function", "String literal as an argument.",
  """
  function take(s: string): i32 {
    return 1;
  }
  function main(): i32 {
    return take(`hi`);
  }
  """)

# ------------------------------------------------------------------- fs
d("171_import_fs_readfile", "Import fs readFile", "fs readFile mapped to the SA fs primitive.",
  """
  import { readFile } from "fs";
  function main(): i32 {
    const d: string = readFile("/tmp/data.txt");
    return 0;
  }
  """)

d("172_import_fs_writefile", "Import fs writeFile", "fs writeFile mapping.",
  """
  import { writeFile } from "fs";
  function main(): i32 {
    writeFile("/tmp/out.txt", `data`);
    return 0;
  }
  """)

d("173_import_fs_open_close", "Import fs open/close", "File handle lifecycle.",
  """
  import { open, close } from "fs";
  function main(): i32 {
    const f: i32 = open("/tmp/data.txt");
    close(f);
    return 0;
  }
  """)

d("174_import_fs_create", "Import fs create", "File creation mapping.",
  """
  import { create } from "fs";
  function main(): i32 {
    const f: i32 = create("/tmp/new.txt");
    return 0;
  }
  """)

d("175_import_fs_read_write", "Import fs read/write", "Read and write on one handle.",
  """
  import { open, read, write, close } from "fs";
  function main(): i32 {
    const f: i32 = open("/tmp/data.txt");
    read(f);
    write(f);
    close(f);
    return 0;
  }
  """)

d("176_import_fs_remove", "Import fs remove", "File removal mapping.",
  """
  import { remove } from "fs";
  function main(): i32 {
    remove("/tmp/gone.txt");
    return 0;
  }
  """)

d("177_import_fs_mkdir", "Import fs mkdir", "Directory creation mapping.",
  """
  import { mkdir } from "fs";
  function main(): i32 {
    mkdir("/tmp/newdir");
    return 0;
  }
  """)

d("178_fs_with_logic", "fs With Control Flow", "Filesystem call inside a conditional.",
  """
  import { readFile } from "fs";
  function main(): i32 {
    const use: i32 = 1;
    if (use) {
      const d: string = readFile("/tmp/data.txt");
    }
    return 0;
  }
  """)

d("179_fs_in_loop", "fs In Loop", "Filesystem call inside a loop.",
  """
  import { readFile } from "fs";
  function main(): i32 {
    for (let i: i32 = 0; i < 2; i++) {
      const d: string = readFile("/tmp/data.txt");
    }
    return 0;
  }
  """)

d("180_fs_and_struct", "fs And Struct", "Filesystem call with a struct local.",
  """
  import { readFile } from "fs";
  interface Cfg { path: string; retries: i32; }
  function main(): i32 {
    const c: Cfg = { path: `x`, retries: 2 };
    const d: string = readFile(c.path);
    return c.retries;
  }
  """)

# ------------------------------------------------------------------ net
d("181_import_net_connect", "Import net tcpConnect", "net tcpConnect mapping.",
  """
  import { tcpConnect } from "net";
  function main(): i32 {
    const s: i32 = tcpConnect("127.0.0.1:8080");
    return 0;
  }
  """)

d("182_import_net_listen", "Import net tcpListen", "net tcpListen mapping.",
  """
  import { tcpListen } from "net";
  function main(): i32 {
    const s: i32 = tcpListen("0.0.0.0:9000");
    return 0;
  }
  """)

d("183_import_net_accept", "Import net tcpAccept", "net tcpAccept mapping.",
  """
  import { tcpListen, tcpAccept } from "net";
  function main(): i32 {
    const l: i32 = tcpListen("0.0.0.0:9000");
    const c: i32 = tcpAccept(l);
    return 0;
  }
  """)

d("184_import_net_rw", "Import net read/write", "Stream read and write.",
  """
  import { tcpConnect, tcpRead, tcpWrite, tcpClose } from "net";
  function main(): i32 {
    const s: i32 = tcpConnect("127.0.0.1:8080");
    tcpRead(s);
    tcpWrite(s);
    tcpClose(s);
    return 0;
  }
  """)

d("185_net_with_loop", "net With Loop", "Network call inside a loop.",
  """
  import { tcpConnect } from "net";
  function main(): i32 {
    for (let i: i32 = 0; i < 2; i++) {
      const s: i32 = tcpConnect("127.0.0.1:8080");
    }
    return 0;
  }
  """)

d("186_net_with_struct", "net With Struct", "Network call with a struct config.",
  """
  import { tcpConnect } from "net";
  interface Endpoint { host: string; port: i32; }
  function main(): i32 {
    const e: Endpoint = { host: `localhost`, port: 8080 };
    const s: i32 = tcpConnect(e.host);
    return e.port;
  }
  """)

d("187_fs_and_net", "fs And Net Together", "Both standard-library modules imported.",
  """
  import { readFile } from "fs";
  import { tcpConnect } from "net";
  function main(): i32 {
    const d: string = readFile("/tmp/data.txt");
    const s: i32 = tcpConnect("127.0.0.1:8080");
    return 0;
  }
  """)

d("188_multiple_fs_imports", "Multiple fs Imports", "Several fs symbols in one import.",
  """
  import { readFile, writeFile, remove } from "fs";
  function main(): i32 {
    const d: string = readFile("/tmp/a.txt");
    writeFile("/tmp/b.txt", d);
    remove("/tmp/a.txt");
    return 0;
  }
  """)

# -------------------------------------------------------- scoping & moves
d("191_block_scope_reuse", "Block Scope Reuse", "Two loops reusing a loop-local name.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 2; i++) { t = t + i; }
    for (let i: i32 = 0; i < 3; i++) { t = t + i; }
    return t;
  }
  """)

d("192_shadow_then_use", "Shadow Then Use", "A local shadowing a parameter's name in a nested block.",
  """
  function main(): i32 {
    const x: i32 = 1;
    if (1 < 2) {
      const y: i32 = x + 1;
    }
    return x;
  }
  """)

d("193_move_between_locals", "Move Between Locals", "A local initialised from another local.",
  """
  function main(): i32 {
    const a: i32 = 5;
    const b: i32 = a;
    return b;
  }
  """)

d("194_move_chain", "Move Chain", "A chain of local-to-local initialisers.",
  """
  function main(): i32 {
    const a: i32 = 1;
    const b: i32 = a;
    const c: i32 = b;
    const d: i32 = c;
    return d;
  }
  """)

d("195_heap_local_scope", "Heap Local Scope", "A struct local released at scope exit.",
  """
  interface Point { x: i32; y: i32; }
  function main() {
    const p: Point = { x: 1, y: 2 };
    p.x = 3;
  }
  """)

d("196_heap_local_loop_body", "Heap Local In Loop Body", "A struct local declared inside a loop body.",
  """
  interface Point { x: i32; }
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) {
      const p: Point = { x: i };
      t = t + p.x;
    }
    return t;
  }
  """)

d("197_heap_local_in_if", "Heap Local In If", "A struct local declared inside an if arm.",
  """
  interface Point { x: i32; }
  function main(): i32 {
    let t: i32 = 0;
    if (1 < 2) {
      const p: Point = { x: 5 };
      t = p.x;
    }
    return t;
  }
  """)

d("198_array_in_block", "Array In Nested Block", "An array declared inside a loop body.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 2; i++) {
      const arr: i32[] = [i, i];
      t = t + arr[1];
    }
    return t;
  }
  """)

d("199_many_locals", "Many Locals", "A function with many scalar locals.",
  """
  function main(): i32 {
    const a: i32 = 1;
    const b: i32 = 2;
    const c: i32 = 3;
    const d: i32 = 4;
    const e: i32 = 5;
    let f: i32 = 6;
    f = f + a + b + c + d + e;
    return f;
  }
  """)

d("200_reassign_heap_struct", "Reassign Heap Struct", "Rebinding a struct-typed local twice.",
  """
  interface Point { x: i32; y: i32; }
  function main(): i32 {
    let p: Point = { x: 1, y: 1 };
    p = { x: 2, y: 2 };
    return p.x + p.y;
  }
  """)

# ------------------------------------------------------------- integration
d("201_state_machine", "State Machine", "A switch-driven state machine.",
  """
  function step(state: i32, ev: i32): i32 {
    let next: i32 = state;
    switch (state) {
      case 0: { next = 1; break; }
      case 1: { next = 2; break; }
      default: { next = 0; }
    }
    return next;
  }
  function main(): i32 {
    return step(0, 1);
  }
  """)

d("202_queue_rotate", "Queue Rotate", "Rotating a counter through a loop.",
  """
  function main(): i32 {
    let i: i32 = 0;
    let acc: i32 = 0;
    while (i < 4) {
      acc = acc + i;
      i = i + 1;
    }
    return acc;
  }
  """)

d("203_event_loop", "Event Loop", "A loop dispatching on a switch.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) {
      switch (i) {
        case 0: { t = t + 1; break; }
        case 1: { t = t + 2; break; }
        default: { t = t + 4; }
      }
    }
    return t;
  }
  """)

d("204_pipeline_stage", "Pipeline Stage", "Data passing through several helpers.",
  """
  function stage1(x: i32): i32 { return x + 1; }
  function stage2(x: i32): i32 { return x * 2; }
  function stage3(x: i32): i32 { return x - 3; }
  function main(): i32 {
    return stage3(stage2(stage1(1)));
  }
  """)

d("205_graph_walk", "Graph Walk", "Iterating an array of indices.",
  """
  function main(): i32 {
    const nodes: i32[] = [0, 1, 2, 3];
    let visited: i32 = 0;
    for (const n of nodes) { visited = visited + 1; }
    return visited;
  }
  """)

d("206_router_table", "Router Table", "Mapping codes to handlers with a switch.",
  """
  interface Route { code: i32; weight: i32; }
  function main(): i32 {
    const r: Route = { code: 1, weight: 100 };
    let out: i32 = 0;
    switch (r.code) {
      case 0: { out = 1; break; }
      case 1: { out = 2; break; }
      default: { out = 3; }
    }
    return out;
  }
  """)

d("207_metrics_counter", "Metrics Counter", "Incrementing counters in a loop.",
  """
  function main(): i32 {
    const metric: string = `requests`;
    let count: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) { count = count + 1; }
    return count;
  }
  """)

d("208_cache_eviction", "Cache Eviction", "A bounded scan with an early break.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i++) {
      if (i == 5) { break; }
      t = t + i;
    }
    return t;
  }
  """)

d("209_protocol_frame", "Protocol Frame", "A struct describing a frame header.",
  """
  interface Header { kind: i32; length: i32; }
  function main(): i32 {
    const h: Header = { kind: 1, length: 64 };
    return h.length;
  }
  """)

d("210_text_index", "Text Index", "Index arithmetic over an array.",
  """
  function main(): i32 {
    const cells: i32[] = [0, 1, 2, 3, 4];
    let t: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) { t = t + cells[i]; }
    return t;
  }
  """)

d("211_scheduler_tree", "Scheduler Tree", "Nested loops over a matrix-shaped array.",
  """
  function main(): i32 {
    const row: i32[] = [1, 2, 3];
    let t: i32 = 0;
    for (let r: i32 = 0; r < 2; r++) {
      for (const v of row) { t = t + v; }
    }
    return t;
  }
  """)

d("212_app_shell", "App Shell", "Argument-shaped config struct plus dispatch.",
  """
  interface Args { verbose: i32; count: i32; }
  function main(): i32 {
    const a: Args = { verbose: 1, count: 3 };
    let t: i32 = 0;
    for (let i: i32 = 0; i < a.count; i++) { t = t + i; }
    return t;
  }
  """)

d("213_db_session", "Db Session", "A session struct with a status switch.",
  """
  interface Session { id: i32; active: i32; }
  function main(): i32 {
    const s: Session = { id: 7, active: 1 };
    let r: i32 = 0;
    switch (s.active) {
      case 0: { r = 0; break; }
      default: { r = s.id; }
    }
    return r;
  }
  """)

d("214_query_plan", "Query Plan", "A plan struct walked with a loop.",
  """
  interface Step { cost: i32; }
  function main(): i32 {
    const steps: i32[] = [3, 5, 7];
    const s: Step = { cost: 2 };
    let total: i32 = s.cost;
    for (const c of steps) { total = total + c; }
    return total;
  }
  """)

d("215_log_aggregator", "Log Aggregator", "Bucketing levels with a switch.",
  """
  interface Level { code: i32; }
  function main(): i32 {
    const l: Level = { code: 2 };
    let out: i32 = 0;
    switch (l.code) {
      case 0: { out = 1; break; }
      case 1: { out = 2; break; }
      case 2: { out = 3; break; }
      default: { out = 0; }
    }
    return out;
  }
  """)

d("216_task_orchestrator", "Task Orchestrator", "Nested dispatch over a work list.",
  """
  function main(): i32 {
    const work: i32[] = [1, 2, 3];
    let done: i32 = 0;
    for (const w of work) {
      switch (w) {
        case 1: { done = done + 1; break; }
        case 2: { done = done + 2; break; }
        default: { done = done + 3; }
      }
    }
    return done;
  }
  """)

d("217_build_pipeline", "Build Pipeline", "Sequential stages over counters.",
  """
  function compile_one(x: i32): i32 { return x + 1; }
  function link_one(x: i32): i32 { return x * 2; }
  function main(): i32 {
    let total: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) { total = link_one(compile_one(i)); }
    return total;
  }
  """)

d("218_release_bundle", "Release Bundle", "Manifest struct plus a build loop.",
  """
  interface Bundle { version: i32; files: i32; }
  function main(): i32 {
    const b: Bundle = { version: 2, files: 12 };
    let t: i32 = 0;
    for (let i: i32 = 0; i < b.files; i = i + 2) { t = t + 1; }
    return t + b.version;
  }
  """)

d("219_full_app", "Full Application", "A larger program combining every supported feature.",
  """
  interface Config { retries: i32; tag: string; }
  enum Mode { Fast, Slow }
  type Count = i32;

  function classify(m: i32): i32 {
    let r: i32 = 0;
    switch (m) {
      case 0: { r = 1; break; }
      case 1: { r = 5; break; }
      default: { r = 9; }
    }
    return r;
  }

  function total(cfg_retries: i32, scale: i32): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < scale; i++) {
      if (i % 2 == 0) { t = t + i; } else { t = t + 1; }
    }
    return t + cfg_retries;
  }

  function main(): i32 {
    const cfg: Config = { retries: 3, tag: `release` };
    const arr: i32[] = [1, 2, 3, 4];
    let sum: i32 = 0;
    for (const v of arr) { sum = sum + v; }
    const c: Count = classify(1);
    return total(cfg.retries, c) + sum;
  }
  """)

d("220_integration_all", "Integration Everything", "Structs, enums, arrays, loops, switch and strings together.",
  """
  interface Cfg { limit: i32; name: string; }
  enum Kind { A, B }
  function bucket(k: i32, n: i32): i32 {
    let r: i32 = 0;
    switch (k) {
      case 0: { r = n; break; }
      case 1: { r = n * 2; break; }
      default: { r = 0; }
    }
    return r;
  }
  function main(): i32 {
    const c: Cfg = { limit: 4, name: `cfg` };
    const arr: i32[] = [5, 6, 7];
    let t: i32 = 0;
    for (const v of arr) {
      if (v > c.limit) { t = t + bucket(1, v); } else { t = t + v; }
    }
    return t;
  }
  """)

# ------------------------------------------------ mixed / regression shapes
d("221_many_functions_distinct_labels", "Many Functions Distinct Labels", "Several functions each with control flow.",
  """
  function a(x: i32): i32 { if (x > 0) { return 1; } return 0; }
  function b(x: i32): i32 { if (x > 0) { return 2; } else { return 0; } }
  function c(x: i32): i32 { let t: i32 = 0; for (let i: i32 = 0; i < x; i++) { t = t + i; } return t; }
  function d(x: i32): i32 { let t: i32 = 0; let i: i32 = 0; while (i < x) { t = t + i; i = i + 1; } return t; }
  function main(): i32 {
    return a(1) + b(1) + c(3) + d(3);
  }
  """)

d("222_loop_with_early_return", "Loop With Early Return", "Return from deep inside nested control flow.",
  """
  function scan(n: i32): i32 {
    for (let i: i32 = 0; i < n; i++) {
      if (i == 1) {
        if (i > 0) { return 99; }
      }
    }
    return 0;
  }
  function main(): i32 {
    return scan(5);
  }
  """)

d("223_switch_then_code", "Switch Then Trailing Code", "Switch followed by more statements.",
  """
  function main(): i32 {
    let t: i32 = 0;
    switch (1) {
      case 1: { t = 1; break; }
      default: { t = 0; }
    }
    for (let i: i32 = 0; i < 3; i++) { t = t + i; }
    return t;
  }
  """)

d("224_if_chain_then_loop", "If Chain Then Loop", "Long if/else chain followed by a loop.",
  """
  function main(): i32 {
    const x: i32 = 5;
    let t: i32 = 0;
    if (x < 3) { t = 1; }
    else if (x < 6) { t = 2; }
    else { t = 3; }
    for (let i: i32 = 0; i < 2; i++) { t = t + i; }
    return t;
  }
  """)

d("225_struct_and_switch_and_loop", "Struct Switch And Loop", "All three combined in one function.",
  """
  interface S { mode: i32; n: i32; }
  function main(): i32 {
    const s: S = { mode: 1, n: 3 };
    let t: i32 = 0;
    for (let i: i32 = 0; i < s.n; i++) {
      switch (s.mode) {
        case 0: { t = t + 1; break; }
        default: { t = t + i; }
      }
    }
    return t;
  }
  """)

d("226_array_of_struct_usage", "Array Of Struct Usage", "Array local and struct local read together.",
  """
  interface Item { weight: i32; }
  function main(): i32 {
    const arr: i32[] = [1, 2, 3];
    const it: Item = { weight: 10 };
    let t: i32 = it.weight;
    for (const v of arr) { t = t + v; }
    return t;
  }
  """)

d("227_recursive_with_array", "Recursion With Array", "Recursive helper that reads an array local.",
  """
  function total_of(arr_len: i32): i32 {
    const arr: i32[] = [1, 2, 3];
    if (arr_len <= 0) { return 0; }
    return arr[0] + total_of(arr_len - 1);
  }
  function main(): i32 {
    return total_of(3);
  }
  """)

d("228_deeply_nested_blocks", "Deeply Nested Blocks", "Four levels of block nesting.",
  """
  function main(): i32 {
    let t: i32 = 0;
    if (1 < 2) {
      if (2 < 3) {
        if (3 < 4) {
          if (4 < 5) { t = 1; }
        }
      }
    }
    return t;
  }
  """)

d("229_loop_with_multiple_breaks", "Loop With Multiple Break Paths", "Two distinct break points.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 10; i++) {
      if (i == 2) { break; }
      if (i == 5) { break; }
      t = t + i;
    }
    return t;
  }
  """)

d("230_expression_heavy", "Expression Heavy", "Long expressions with many operators.",
  """
  function main(): i32 {
    const a: i32 = 2;
    const b: i32 = 3;
    const c: i32 = 4;
    // Integer arithmetic only: the supported subset maps TypeScript `/` to the
    // integer `div`, so a program relying on TypeScript float division is out of
    // scope. See REQUIREMENTS.md.
    return a * b + c * 2 - 1 + (a + b) * (c - 1) * 2;
  }
  """)

d("231_comparison_in_loop_condition", "Comparison In Loop Condition", "Parameterised loop bound.",
  """
  function main(): i32 {
    const n: i32 = 6;
    let t: i32 = 0;
    let i: i32 = 0;
    while (i < n && t < 100) {
      t = t + i;
      i = i + 1;
    }
    return t;
  }
  """)

d("232_struct_field_chained_ops", "Struct Field Chained Ops", "Arithmetic over several struct fields.",
  """
  interface V3 { x: i32; y: i32; z: i32; }
  function main(): i32 {
    const v: V3 = { x: 1, y: 2, z: 3 };
    return v.x * v.y + v.z - v.x;
  }
  """)

d("233_enum_switch_in_while", "Enum Switch In While", "Switch inside a while loop.",
  """
  enum Mode { A, B, C }
  function main(): i32 {
    const m: i32 = 1;
    let t: i32 = 0;
    let i: i32 = 0;
    while (i < 3) {
      switch (m) {
        case 0: { t = t + 1; break; }
        case 1: { t = t + 2; break; }
        default: { t = t + 3; }
      }
      i = i + 1;
    }
    return t;
  }
  """)

d("234_typed_array_of_structs_shape", "Typed Array With Struct Locals", "Typed array and struct locals side by side.",
  """
  interface P { x: i32; y: i32; }
  function main(): i32 {
    const arr: i32[] = [1, 2, 3, 4];
    const a: P = { x: 1, y: 2 };
    const b: P = { x: 3, y: 4 };
    let t: i32 = 0;
    for (const v of arr) { t = t + v + a.x + b.y; }
    return t;
  }
  """)

d("235_void_with_loop", "Void Function With Loop", "Void function containing a loop.",
  """
  function compute(n: i32) {
    let t: i32 = 0;
    for (let i: i32 = 0; i < n; i++) { t = t + i; }
  }
  function main() {
    compute(5);
  }
  """)

d("236_no_return_heap_struct_write", "No Return Heap Struct Write", "Mutating a struct in a void function.",
  """
  interface Counter { value: i32; }
  function bump(c: Counter) {
    c.value = 1;
  }
  function main() {
    const c: Counter = { value: 0 };
    bump(c);
  }
  """)

d("237_guard_then_loop", "Guard Then Loop", "Guards followed by a loop.",
  """
  function run(n: i32): i32 {
    if (n < 0) { return 0; }
    if (n == 0) { return 1; }
    let t: i32 = 0;
    for (let i: i32 = 0; i < n; i++) { t = t + i; }
    return t;
  }
  function main(): i32 {
    return run(4);
  }
  """)

d("238_nested_function_calls_in_loop", "Nested Calls In Loop", "Calls nested inside a loop body.",
  """
  function dbl(x: i32): i32 { return x * 2; }
  function inc(x: i32): i32 { return x + 1; }
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 3; i++) { t = dbl(inc(i)); }
    return t;
  }
  """)

d("239_struct_in_switch_arm", "Struct Local In Switch Arm", "A struct declared inside a case body.",
  """
  interface P { x: i32; }
  function main(): i32 {
    let t: i32 = 0;
    switch (1) {
      case 1: {
        const p: P = { x: 4 };
        t = p.x;
        break;
      }
      default: { t = 0; }
    }
    return t;
  }
  """)

d("240_array_write_in_loop", "Array Write In Loop", "Writing array elements from a loop.",
  """
  function main(): i32 {
    let arr: i32[] = [0, 0, 0, 0];
    for (let i: i32 = 0; i < 4; i++) { arr[i] = i * 2; }
    return arr[3];
  }
  """)

d("241_const_vs_let", "Const Versus Let", "Both binding kinds in one function.",
  """
  function main(): i32 {
    const fixed: i32 = 1;
    let mutable: i32 = 2;
    mutable = mutable + fixed;
    return mutable;
  }
  """)

d("242_bool_logic_deep", "Boolean Logic Deep", "Multi-term boolean conditions.",
  """
  function ok(a: i32, b: i32, c: i32): i32 {
    if (a > 0 && b > 0 && c > 0) { return 1; }
    return 0;
  }
  function main(): i32 {
    return ok(1, 2, 3);
  }
  """)

d("243_bool_logic_mixed", "Boolean Logic Mixed", "`&&` and `||` in one condition.",
  """
  function main(): i32 {
    const a: i32 = 1;
    const b: i32 = 0;
    if (a > 0 || b > 0 && a > 5) { return 1; }
    return 0;
  }
  """)

d("244_nested_struct_params", "Nested Struct Params", "Two struct parameters combined.",
  """
  interface A { v: i32; }
  interface B { w: i32; }
  function combine(a: A, b: B): i32 {
    return a.v + b.w;
  }
  function main(): i32 {
    const a: A = { v: 1 };
    const b: B = { w: 2 };
    return combine(a, b);
  }
  """)

d("245_wide_switch", "Wide Switch", "Eight-case dispatch.",
  """
  function m(c: i32): i32 {
    let r: i32 = 0;
    switch (c) {
      case 0: { r = 0; break; }
      case 1: { r = 1; break; }
      case 2: { r = 2; break; }
      case 3: { r = 3; break; }
      case 4: { r = 4; break; }
      case 5: { r = 5; break; }
      case 6: { r = 6; break; }
      default: { r = 7; }
    }
    return r;
  }
  function main(): i32 {
    return m(3);
  }
  """)

d("246_loop_break_continue_shape", "Loop Break Continue Shape", "Break and return together.",
  """
  function main(): i32 {
    let t: i32 = 0;
    for (let i: i32 = 0; i < 5; i++) {
      if (i == 2) { break; }
      t = t + i;
    }
    return t;
  }
  """)

d("247_string_and_numbers", "String And Numbers", "String literal and counters in one scope.",
  """
  function main(): i32 {
    const label: string = `total`;
    const base: i32 = 10;
    let t: i32 = base;
    for (let i: i32 = 0; i < 3; i++) { t = t + i; }
    return t;
  }
  """)

d("248_interfaces_only", "Interfaces Only", "Several interface declarations.",
  """
  interface A { a: i32; }
  interface B { b: i32; }
  interface C { c: i32; }
  function main(): i32 {
    const a: A = { a: 1 };
    const b: B = { b: 2 };
    const c: C = { c: 3 };
    return a.a + b.b + c.c;
  }
  """)

d("249_enums_only", "Enums Only", "Several enum declarations.",
  """
  enum A { X, Y }
  enum B { P, Q }
  enum C { M, N }
  function main(): i32 {
    const a: i32 = 0;
    const b: i32 = 1;
    return a + b;
  }
  """)

d("250_declarations_only", "Declarations Only", "A file of type aliases and enums.",
  """
  type A = i32;
  type B = i32;
  enum S { Idle, Busy }
  function main(): i32 {
    return 0;
  }
  """)

d("251_kitchen_sink", "Kitchen Sink", "End-to-end coverage: arithmetic, control flow, arrays, structs, recursion and enums in one program.",
  """
  type Score = i32;

  interface Point {
    x: i32;
    y: i32;
  }

  enum Color {
    Red,
    Green,
    Blue
  }

  function max(a: i32, b: i32): i32 {
    if (a > b) { return a; } else { return b; }
  }

  function negate(x: i32): i32 {
    return 0 - x;
  }

  function fact(n: i32): i32 {
    if (n <= 1) { return 1; }
    return n * fact(n - 1);
  }

  function fib(n: i32): i32 {
    if (n < 2) { return n; }
    return fib(n - 1) + fib(n - 2);
  }

  function classify(c: i32): i32 {
    let r: i32 = 0;
    switch (c) {
      case 0: { r = 10; break; }
      case 1: { r = 20; break; }
      default: { r = 30; }
    }
    return r;
  }

  function bucket(x: i32): i32 {
    if (x < 0) { return 0 - 1; }
    else if (x == 0) { return 0; }
    else if (x < 10) { return 1; }
    else { return 2; }
  }

  function logIt(x: i32) {
    let y: i32 = x + 1;
  }

  function main(): i32 {
    const label: string = `kitchen-sink`;

    // arithmetic, precedence, modulo, alias, const/let
    const base: Score = 2 + 3 * 4 - 6 / 2;
    let total: i32 = base + 17 % 5;

    // equality + logical and
    if (total == 13 && total > 10) {
      total = total + 100;
    } else {
      total = total - 100;
    }

    // else-if chain, max, unary minus, void call
    total = total + bucket(5) * 10;
    total = max(total, 50) + negate(3);
    logIt(total);

    // while + break
    let i: i32 = 0;
    while (i < 100) {
      if (i >= 5) { break; }
      total = total + i;
      i = i + 1;
    }

    // c-style for
    for (let j = 0; j < 4; j++) { total = total + j; }

    // array literal, index read/write, for-of sum
    let arr: i32[] = [1, 2, 3, 4];
    arr[0] = 10;
    arr[3] = arr[1] + arr[2];
    let t: i32 = 0;
    for (const v of arr) { t = t + v; }
    total = total + t;

    // struct literal, field read/write
    const p: Point = { x: 3, y: 4 };
    total = total + p.x * p.y;
    p.x = 30;
    total = total + p.x;

    // recursion
    total = total + fact(4) + fib(8);

    // enum-driven switch
    total = total + classify(1) + classify(9);

    // loop variable reuse across loops
    for (let k = 0; k < 2; k++) { total = total + k; }
    for (let k = 0; k < 3; k++) { total = total + k; }

    // switch on loop variable
    for (let m = 0; m < 5; m++) {
      switch (m) {
        case 3: { total = total + 500; break; }
        default: { total = total + m; }
      }
      total = total + 1;
    }

    return total;
  }
  """)


def main():
    names = [x[0] for x in D]
    assert len(names) == len(set(names)), "duplicate demo dir"
    os.makedirs(DEMOS, exist_ok=True)
    for name, title, blurb, src in D:
        ddir = os.path.join(DEMOS, name)
        os.makedirs(ddir, exist_ok=True)
        with open(os.path.join(ddir, "main.ts"), "w", encoding="utf-8") as f:
            f.write(src)
        with open(os.path.join(ddir, "README.md"), "w", encoding="utf-8") as f:
            f.write("# %s\n\n%s\n\n- `main.ts`: TypeScript source for this slot.\n" % (title, blurb))
    print("generated %d demos in %s" % (len(D), DEMOS))


if __name__ == "__main__":
    main()
