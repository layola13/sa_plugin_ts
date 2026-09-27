interface Session { id: i32; active: i32; }
function main(): i32 {
  const s: Session = { id: 7, active: 1 };
  let r: i32 = 0;
  switch (s.active) {
    case 0: { r = 0; break; }
    default: { r = s.id; }
  }
  return r;
}
