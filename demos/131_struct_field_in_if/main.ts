interface Limit { max: i32; }
function main(): i32 {
  const l: Limit = { max: 10 };
  if (l.max > 5) { return 1; }
  return 0;
}
