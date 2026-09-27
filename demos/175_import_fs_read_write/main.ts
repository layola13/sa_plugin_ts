import { open, read, write, close } from "fs";
function main(): i32 {
  const f: i32 = open("/tmp/data.txt");
  read(f);
  write(f);
  close(f);
  return 0;
}
