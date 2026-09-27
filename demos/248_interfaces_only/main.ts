interface A { a: i32; }
interface B { b: i32; }
interface C { c: i32; }
function main(): i32 {
  const a: A = { a: 1 };
  const b: B = { b: 2 };
  const c: C = { c: 3 };
  return a.a + b.b + c.c;
}
