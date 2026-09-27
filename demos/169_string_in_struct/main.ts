interface Named { name: string; id: i32; }
function main(): i32 {
  const n: Named = { name: `thing`, id: 1 };
  return n.id;
}
