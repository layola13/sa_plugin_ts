async function main(): i32 {
  const v = await wrap();
  return v;
}

async function fetch(): i32 {
  return 41;
}

async function wrap(): i32 {
  const v = await fetch();
  return v + 1;
}
