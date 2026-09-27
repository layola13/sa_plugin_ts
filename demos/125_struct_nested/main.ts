interface Inner { a: i32; b: i32; }
interface Outer { inner: Inner; tag: i32; }
function main(): i32 {
  const o: Outer = { inner: { a: 1, b: 2 }, tag: 3 };
  return o.tag;
}
