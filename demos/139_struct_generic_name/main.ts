interface Box<T> { value: T; }
function main(): i32 {
  const b: Box = { value: 5 };
  return b.value;
}
