import { readFile } from "fs";
function main(): i32 {
  for (let i: i32 = 0; i < 2; i++) {
    const d: string = readFile("/tmp/data.txt");
  }
  return 0;
}
