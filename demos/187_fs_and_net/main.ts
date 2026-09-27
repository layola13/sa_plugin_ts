import { readFile } from "fs";
import { tcpConnect } from "net";
function main(): i32 {
  const d: string = readFile("/tmp/data.txt");
  const s: i32 = tcpConnect("127.0.0.1:8080");
  return 0;
}
