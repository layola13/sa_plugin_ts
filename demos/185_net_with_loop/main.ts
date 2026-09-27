import { tcpConnect } from "net";
function main(): i32 {
  for (let i: i32 = 0; i < 2; i++) {
    const s: i32 = tcpConnect("127.0.0.1:8080");
  }
  return 0;
}
