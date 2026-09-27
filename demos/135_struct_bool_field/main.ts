interface Flags { ready: i32; count: i32; }
function main(): i32 {
  const f: Flags = { ready: 1, count: 4 };
  let r: i32 = 0;
  if (f.ready) { r = f.count; }
  return r;
}
