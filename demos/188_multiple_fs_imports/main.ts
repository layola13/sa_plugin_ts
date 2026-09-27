import { readFile, writeFile, remove } from "fs";
function main(): i32 {
  const d: string = readFile("/tmp/a.txt");
  writeFile("/tmp/b.txt", d);
  remove("/tmp/a.txt");
  return 0;
}
