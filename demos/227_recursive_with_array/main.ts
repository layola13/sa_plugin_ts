function total_of(arr_len: i32): i32 {
  const arr: i32[] = [1, 2, 3];
  if (arr_len <= 0) { return 0; }
  return arr[0] + total_of(arr_len - 1);
}
function main(): i32 {
  return total_of(3);
}
