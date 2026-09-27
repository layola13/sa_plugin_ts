function classify(x: i32): i32 {
  let r: i32 = 0;
  if (x > 0) { r = 1; }
  return r;
}
function main(): i32 {
  return classify(3);
}
