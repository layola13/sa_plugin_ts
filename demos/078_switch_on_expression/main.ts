function classify(n: i32): i32 {
  const bucket: i32 = n % 3;
  let r: i32 = 0;
  switch (bucket) {
    case 0: { r = 100; break; }
    case 1: { r = 200; break; }
    default: { r = 300; }
  }
  return r;
}
function main(): i32 {
  return classify(7);
}
