import { tcpListen } from "net";
function main(): i32 {
  const s: i32 = tcpListen("0.0.0.0:9000");
  return 0;
}
