interface State { code: i32; }
function main(): i32 {
  const s: State = { code: 2 };
  let r: i32 = 0;
  switch (s.code) {
    case 1: { r = 10; break; }
    case 2: { r = 20; break; }
    default: { r = 0; }
  }
  return r;
}
