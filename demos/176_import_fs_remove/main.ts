import { remove } from "fs";
function main(): i32 {
  remove("/tmp/gone.txt");
  return 0;
}
