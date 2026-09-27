interface Item { weight: i32; }
function main(): i32 {
  const arr: i32[] = [1, 2, 3];
  const it: Item = { weight: 10 };
  let t: i32 = it.weight;
  for (const v of arr) { t = t + v; }
  return t;
}
