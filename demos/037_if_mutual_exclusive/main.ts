function classify(x: i32): i32 {
  let r: i32 = 0;
  if (x == 1) { r = 10; }
  if (x == 2) { r = 20; }
  return r;
}
function main(): i32 {
  return classify(2);
}
