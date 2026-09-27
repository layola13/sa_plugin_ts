interface Counter { value: i32; }
function bump(c: Counter) {
  c.value = 1;
}
function main() {
  const c: Counter = { value: 0 };
  bump(c);
}
