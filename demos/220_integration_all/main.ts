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
