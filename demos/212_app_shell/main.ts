interface Args { verbose: i32; count: i32; }
function main(): i32 {
  const a: Args = { verbose: 1, count: 3 };
  let t: i32 = 0;
  for (let i: i32 = 0; i < a.count; i++) { t = t + i; }
  return t;
}
