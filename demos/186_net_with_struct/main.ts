import { tcpConnect } from "net";
interface Endpoint { host: string; port: i32; }
function main(): i32 {
  const e: Endpoint = { host: `localhost`, port: 8080 };
  const s: i32 = tcpConnect(e.host);
  return e.port;
}
