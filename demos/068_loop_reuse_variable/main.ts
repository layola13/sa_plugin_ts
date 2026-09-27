function main(): i32 {
  let carry: i32 = 0;
  for (let i: i32 = 0; i < 4; i++) { carry = carry + i; }
  return carry;
}
