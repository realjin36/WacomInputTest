import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const host = "127.0.0.1";
const root = path.dirname(fileURLToPath(import.meta.url));
const files = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/app.js", ["app.js", "text/javascript; charset=utf-8"]],
  ["/styles.css", ["styles.css", "text/css; charset=utf-8"]]
]);

function parsePort(args) {
  let port = 8080;
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] !== "--port" || index + 1 >= args.length) {
      throw new Error(`Unknown or incomplete argument: ${args[index]}`);
    }
    const value = Number(args[++index]);
    if (!Number.isInteger(value) || value < 1 || value > 65535) {
      throw new Error("--port must be an integer between 1 and 65535.");
    }
    port = value;
  }
  return port;
}

let port;
try {
  port = parsePort(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exit(64);
}

const server = http.createServer(async (request, response) => {
  const requestUrl = new URL(request.url || "/", `http://${host}:${port}`);
  const asset = request.method === "GET" ? files.get(requestUrl.pathname) : null;
  if (!asset) {
    response.writeHead(404, {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-store"
    });
    response.end("Not found");
    return;
  }

  try {
    const [fileName, contentType] = asset;
    const body = await fs.readFile(path.join(root, fileName));
    response.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": body.length,
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff"
    });
    response.end(body);
  } catch (error) {
    console.error(error);
    response.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Failed to read example asset");
  }
});

server.on("error", error => {
  console.error(`Example monitor server failed: ${error.message}`);
  process.exitCode = 1;
});

server.listen(port, host, () => {
  console.log(`Wacom bridge example monitor: http://${host}:${port}`);
  console.log(`Default bridge: http://127.0.0.1:8765`);
  console.log(`Override example: http://${host}:${port}/?bridge=http://127.0.0.1:9876`);
});

function stop() {
  server.close(error => {
    if (error) {
      console.error(error);
      process.exitCode = 1;
    }
  });
}

process.on("SIGINT", stop);
process.on("SIGTERM", stop);
