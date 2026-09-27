import { tcpConnect, tcpRead, tcpWrite, tcpClose } from "net";
function main(): i32 {
  const s: i32 = tcpConnect("127.0.0.1:8080");
  tcpRead(s);
  tcpWrite(s);
  tcpClose(s);
  return 0;
}
