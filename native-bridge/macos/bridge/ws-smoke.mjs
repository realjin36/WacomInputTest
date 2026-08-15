import crypto from "node:crypto";
import net from "node:net";

const port = Number(process.argv[2] || 8765);
const key = crypto.randomBytes(16).toString("base64");
const expectedAccept = crypto
  .createHash("sha1")
  .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
  .digest("base64");

function maskedTextFrame(text) {
  const payload = Buffer.from(text);
  const mask = crypto.randomBytes(4);
  const header = payload.length <= 125
    ? Buffer.from([0x81, 0x80 | payload.length])
    : Buffer.from([0x81, 0x80 | 126, payload.length >> 8, payload.length & 0xff]);
  const masked = Buffer.alloc(payload.length);
  for (let index = 0; index < payload.length; index += 1) {
    masked[index] = payload[index] ^ mask[index % 4];
  }
  return Buffer.concat([header, mask, masked]);
}

function parseServerFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  let length = buffer[1] & 0x7f;
  let offset = 2;
  if (length === 126) {
    if (buffer.length < 4) return null;
    length = buffer.readUInt16BE(2);
    offset = 4;
  } else if (length === 127) {
    if (buffer.length < 10) return null;
    const wideLength = buffer.readBigUInt64BE(2);
    if (wideLength > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("Frame too large");
    length = Number(wideLength);
    offset = 10;
  }
  if (buffer.length < offset + length) return null;
  return { opcode, payload: buffer.subarray(offset, offset + length), consumed: offset + length };
}

await new Promise((resolve, reject) => {
  const socket = net.createConnection({ host: "127.0.0.1", port });
  let buffer = Buffer.alloc(0);
  let upgraded = false;
  const timeout = setTimeout(() => {
    socket.destroy();
    reject(new Error("WebSocket smoke test timed out"));
  }, 5000);

  socket.on("connect", () => {
    socket.write(
      `GET /ws HTTP/1.1\r\n` +
      `Host: 127.0.0.1:${port}\r\n` +
      `Upgrade: websocket\r\n` +
      `Connection: Upgrade\r\n` +
      `Sec-WebSocket-Version: 13\r\n` +
      `Sec-WebSocket-Key: ${key}\r\n\r\n`
    );
  });

  socket.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (!upgraded) {
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const headers = buffer.subarray(0, end).toString("utf8");
      if (!headers.startsWith("HTTP/1.1 101")) throw new Error(`Unexpected handshake: ${headers}`);
      if (!headers.toLowerCase().includes(`sec-websocket-accept: ${expectedAccept}`.toLowerCase())) {
        throw new Error("Invalid Sec-WebSocket-Accept");
      }
      upgraded = true;
      buffer = buffer.subarray(end + 4);
    }

    const frame = parseServerFrame(buffer);
    if (!frame) return;
    if (frame.opcode !== 1) throw new Error(`Unexpected opcode ${frame.opcode}`);
    const hello = JSON.parse(frame.payload.toString("utf8"));
    if (hello.type !== "bridge.hello" || hello.protocolVersion !== 2) {
      throw new Error("Missing protocol 2 bridge.hello");
    }
    if (!hello.status?.native?.touchReady || !hello.status?.native?.penReady) {
      throw new Error("Native input is not ready in bridge.hello");
    }
    socket.write(
      maskedTextFrame(JSON.stringify({ type: "bridge.activate", generation: 1 })),
      () => {
        clearTimeout(timeout);
        socket.destroy();
        resolve();
      }
    );
  });

  socket.on("error", error => {
    clearTimeout(timeout);
    reject(error);
  });
});

console.log("websocket=ok protocolVersion=2 hello=ok");
