interface Step { cost: i32; }
function main(): i32 {
  const steps: i32[] = [3, 5, 7];
  const s: Step = { cost: 2 };
  let total: i32 = s.cost;
  for (const c of steps) { total = total + c; }
  return total;
}
