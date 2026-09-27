interface Route { code: i32; weight: i32; }
function main(): i32 {
  const r: Route = { code: 1, weight: 100 };
  let out: i32 = 0;
  switch (r.code) {
    case 0: { out = 1; break; }
    case 1: { out = 2; break; }
    default: { out = 3; }
  }
  return out;
}
