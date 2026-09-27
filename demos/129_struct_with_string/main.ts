interface Named { name: string; id: i32; }
function main(): i32 {
  const n: Named = { name: `widget`, id: 7 };
  return n.id;
}
