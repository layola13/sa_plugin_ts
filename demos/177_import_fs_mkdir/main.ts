import { mkdir } from "fs";
function main(): i32 {
  mkdir("/tmp/newdir");
  return 0;
}
