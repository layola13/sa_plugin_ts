export function head(pair: [number, number]): number {
  return pair[0];
}
export function secondRow(mat: [number, number][][]): number {
  return mat[1][0][1];
}
function main(): i32 {
  const p: [number, number] = [7, 8];
  const m: [number, number][][] = [[[1, 2]], [[3, 4]]];
  return head(p) + secondRow(m);
}
