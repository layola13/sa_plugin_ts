import { tcpListen, tcpAccept } from "net";
function main(): i32 {
  const l: i32 = tcpListen("0.0.0.0:9000");
  const c: i32 = tcpAccept(l);
  return 0;
}
