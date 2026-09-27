import { open, close } from "fs";
function main(): i32 {
  const f: i32 = open("/tmp/data.txt");
  close(f);
  return 0;
}
