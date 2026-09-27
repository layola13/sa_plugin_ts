function main(): i32 {
  const metric: string = `requests`;
  let count: i32 = 0;
  for (let i: i32 = 0; i < 5; i++) { count = count + 1; }
  return count;
}
