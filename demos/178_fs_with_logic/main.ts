import { readFile } from "fs";
function main(): i32 {
  const use: i32 = 1;
  if (use) {
    const d: string = readFile("/tmp/data.txt");
  }
  return 0;
}
