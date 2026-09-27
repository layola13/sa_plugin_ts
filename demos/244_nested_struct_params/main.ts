interface A { v: i32; }
interface B { w: i32; }
function combine(a: A, b: B): i32 {
  return a.v + b.w;
}
function main(): i32 {
  const a: A = { v: 1 };
  const b: B = { w: 2 };
  return combine(a, b);
}
