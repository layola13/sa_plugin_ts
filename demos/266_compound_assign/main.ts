function main(): i32 {
  let a: i32 = 3;
  a += 4;
  a -= 2;
  a *= 6;
  a /= 5;
  a %= 4;
  let b: i32 = 16;
  b >>= 2;
  b <<= 1;
  let c: i32 = 0;
  for (let i = 0; i < 3; i += 2) { c = c + i; }
  return a * 100 + b * 10 + c;
}
