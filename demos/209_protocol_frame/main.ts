interface Header { kind: i32; length: i32; }
function main(): i32 {
  const h: Header = { kind: 1, length: 64 };
  return h.length;
}
