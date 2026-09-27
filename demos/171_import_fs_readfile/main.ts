import { readFile } from "fs";
function main(): i32 {
  const d: string = readFile("/tmp/data.txt");
  return 0;
}
