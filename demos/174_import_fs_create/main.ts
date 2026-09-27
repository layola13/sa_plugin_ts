import { create } from "fs";
function main(): i32 {
  const f: i32 = create("/tmp/new.txt");
  return 0;
}
