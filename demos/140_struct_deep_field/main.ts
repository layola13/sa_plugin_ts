interface Inner { a: i32; b: i32; }
interface Outer { inner: Inner; tag: i32; }
function main(): i32 {
  const o: Outer = { inner: { a: 9, b: 8 }, tag: 1 };
  return o.inner.a;
}
