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
