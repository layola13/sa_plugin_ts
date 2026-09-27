import { writeFile } from "fs";
function main(): i32 {
  writeFile("/tmp/out.txt", `data`);
  return 0;
}
