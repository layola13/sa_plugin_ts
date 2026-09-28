async function main(): i32 {
  const v = await fetch();
  return v + 1;
}

async function fetch(): i32 {
  return 41;
}
