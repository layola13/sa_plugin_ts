function get(a: number[], i: i32): i32 {
  return a?.[i];
}
function pick(c: i32): i32 {
  const t = c?.5:7;
  return t;
}
function main(): i32 {
  const a: number[] = [10, 20];
  return get(a, 1) + pick(0);
}
