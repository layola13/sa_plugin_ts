interface Level { code: i32; }
function main(): i32 {
  const l: Level = { code: 2 };
  let out: i32 = 0;
  switch (l.code) {
    case 0: { out = 1; break; }
    case 1: { out = 2; break; }
    case 2: { out = 3; break; }
    default: { out = 0; }
  }
  return out;
}
