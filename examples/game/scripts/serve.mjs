// dist/（vite build の結果）を返すだけの小さなサーバー。画面を撮る道具（shot.mjs --serve）が npm run start で使う。
// 港の番号は -p <番号> か環境変数 PORT（無ければ 4173）
import { createServer } from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";

const i = process.argv.indexOf("-p");
const port = Number(i >= 0 ? process.argv[i + 1] : process.env.PORT || 4173);
const root = resolve("dist");
const types = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".json": "application/json", ".woff2": "font/woff2", ".mp3": "audio/mpeg", ".ogg": "audio/ogg", ".wav": "audio/wav" };

createServer((req, res) => {
  let file = resolve(join(root, decodeURIComponent(new URL(req.url ?? "/", "http://x").pathname)));
  if (file !== root && !file.startsWith(root + sep)) {
    res.writeHead(403);
    return res.end();
  }
  if (!existsSync(file) || statSync(file).isDirectory()) file = join(root, "index.html");
  res.writeHead(200, { "content-type": types[extname(file).toLowerCase()] ?? "application/octet-stream" });
  createReadStream(file).pipe(res);
}).listen(port, "127.0.0.1", () => console.log(`http://127.0.0.1:${port}/`));
