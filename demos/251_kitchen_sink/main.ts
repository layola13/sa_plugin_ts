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
