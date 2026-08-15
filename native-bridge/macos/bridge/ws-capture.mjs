import crypto from "node:crypto";
import net from "node:net";

const port = Number(process.argv[2] || 8765);
const durationMs = Math.max(1000, Number(process.argv[3] || 18000));
const key = crypto.randomBytes(16).toString("base64");
const summary = {
  hello: false,
  protocolVersion: 0,
  events: 0,
  touchFrames: 0,
  touchContacts: 0,
  maxTouches: 0,
  penPackets: 0,
  positivePressurePackets: 0,
  proximityMessages: 0,
  sequenceGaps: 0,
  firstSequence: 0,
  lastSequence: 0,
  invalidMessages: 0
};

function maskedTextFrame(text) {
  const payload = Buffer.from(text);
  const mask = crypto.randomBytes(4);
  const header = Buffer.from([0x81, 0x80 | payload.length]);
  const masked = Buffer.alloc(payload.length);
  for (let index = 0; index < payload.length; index += 1) masked[index] = payload[index] ^ mask[index % 4];
  return Buffer.concat([header, mask, masked]);
}

function nextFrame(buffer) {
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

function recordMessage(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
  if (message.type === "bridge.hello") {
    summary.hello = true;
    summary.protocolVersion = message.protocolVersion;
    if (!message.status?.native?.touchReady || !message.status?.native?.penReady) summary.invalidMessages += 1;
    return;
  }

  summary.events += 1;
  if (!Number.isFinite(message.sequence)) {
    summary.invalidMessages += 1;
  } else {
    if (!summary.firstSequence) summary.firstSequence = message.sequence;
    if (summary.lastSequence && message.sequence > summary.lastSequence + 1) {
      summary.sequenceGaps += message.sequence - summary.lastSequence - 1;
    }
    summary.lastSequence = Math.max(summary.lastSequence, message.sequence);
  }

  if (message.type === "touch.frame") {
    summary.touchFrames += 1;
    const contacts = message.touch?.contacts;
    if (!Array.isArray(contacts)) {
      summary.invalidMessages += 1;
      return;
    }
    summary.touchContacts += contacts.length;
    summary.maxTouches = Math.max(summary.maxTouches, contacts.length);
    if (contacts.some(contact => !contact.state || !contact.commonState || !Number.isFinite(contact.x))) {
      summary.invalidMessages += 1;
    }
  } else if (message.type === "pen.packet") {
    summary.penPackets += 1;
    const pen = message.pen;
    if (pen?.normalizedPressure > 0) summary.positivePressurePackets += 1;
    if (!pen || !Number.isFinite(pen.screenX) || !Number.isFinite(pen.screenY) ||
        !Number.isFinite(pen.absoluteX) || !Number.isFinite(pen.tiltX) || !pen.pointingDeviceType) {
      summary.invalidMessages += 1;
    }
  } else if (message.type === "pen.proximity") {
    summary.proximityMessages += 1;
    if (typeof message.proximity?.entering !== "boolean" || !message.proximity?.pointingDeviceType) {
      summary.invalidMessages += 1;
    }
  } else {
    summary.invalidMessages += 1;
  }
}

const socket = net.createConnection({ host: "127.0.0.1", port });
let buffer = Buffer.alloc(0);
let upgraded = false;
let finished = false;

function finish(exitCode = 0) {
  if (finished) return;
  finished = true;
  socket.destroy();
  process.stderr.write(`${JSON.stringify(summary)}\n`);
  process.exitCode = exitCode;
}

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
    if (!headers.startsWith("HTTP/1.1 101")) {
      finish(2);
      return;
    }
    upgraded = true;
    buffer = buffer.subarray(end + 4);
    socket.write(maskedTextFrame(JSON.stringify({ type: "bridge.activate", generation: 1 })));
  }

  while (true) {
    const frame = nextFrame(buffer);
    if (!frame) break;
    buffer = buffer.subarray(frame.consumed);
    if (frame.opcode === 1) {
      try {
        recordMessage(JSON.parse(frame.payload.toString("utf8")));
      } catch (_) {
        summary.invalidMessages += 1;
      }
    }
  }
});

socket.on("error", () => finish(2));
socket.on("close", () => {
  if (!finished) finish(summary.hello ? 0 : 2);
});

setTimeout(() => {
  const ok = summary.hello && summary.protocolVersion === 2 &&
    summary.touchFrames > 0 && summary.penPackets > 0 && summary.proximityMessages > 0 &&
    summary.sequenceGaps === 0 && summary.invalidMessages === 0;
  finish(ok ? 0 : 3);
}, durationMs);

