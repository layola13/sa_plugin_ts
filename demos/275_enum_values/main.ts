export enum Cal {
  A,
  B,
  C
}
export function isB(c: Cal): i32 {
  if (c === Cal.B) { return 1; }
  return 0;
}
function main(): i32 {
  return Cal.A * 100 + Cal.B * 10 + Cal.C + isB(1);
}
