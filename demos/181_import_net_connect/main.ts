import { tcpConnect } from "net";
function main(): i32 {
  const s: i32 = tcpConnect("127.0.0.1:8080");
  return 0;
}
