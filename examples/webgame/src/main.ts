import { clamp } from "./lib/clamp";

// 雛形：画面いっぱいの canvas に、タイトルと動く点を描くだけ。工場のデザイン担当が、ここから本物のゲームを作る
const canvas = document.querySelector<HTMLCanvasElement>("#game");
if (!canvas) throw new Error("canvas がありません");
const ctx = canvas.getContext("2d");
if (!ctx) throw new Error("2D の描画が使えません");

function resize(): void {
  const dpr = window.devicePixelRatio || 1;
  canvas!.width = Math.floor(window.innerWidth * dpr);
  canvas!.height = Math.floor(window.innerHeight * dpr);
  ctx!.setTransform(dpr, 0, 0, dpr, 0, 0);
}
window.addEventListener("resize", resize);
resize();

let x = 0;
function frame(t: number): void {
  const w = window.innerWidth;
  const h = window.innerHeight;
  ctx!.fillStyle = "#000";
  ctx!.fillRect(0, 0, w, h);
  ctx!.fillStyle = "#fff";
  ctx!.font = "48px sans-serif";
  ctx!.textAlign = "center";
  ctx!.fillText("Game", w / 2, h / 2);
  x = clamp(w / 2 + Math.sin(t / 600) * 200, 0, w);
  ctx!.beginPath();
  ctx!.arc(x, h / 2 + 60, 8, 0, Math.PI * 2);
  ctx!.fill();
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
