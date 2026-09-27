interface P { x: i32; }
function main(): i32 {
  let t: i32 = 0;
  switch (1) {
    case 1: {
      const p: P = { x: 4 };
      t = p.x;
      break;
    }
    default: { t = 0; }
  }
  return t;
}
