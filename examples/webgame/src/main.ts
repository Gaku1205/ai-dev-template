import { clamp } from "./lib/clamp";

// 雛形：画面いっぱいの canvas に、タイトルと動く点を描くだけ。工場のデザイン担当が、ここから本物のゲームを作る
// 日本語の書体は同梱の "GameJP"（index.html の @font-face。端末の書体は予備）。canvas は読み込み前に描くと別の書体になるので、読み込みを待ってから描き始める
export const JP_FONT = '"GameJP", "Hiragino Sans", "Yu Gothic UI", "Meiryo", "Noto Sans JP", sans-serif';
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
  ctx!.font = `700 48px ${JP_FONT}`;
  ctx!.textAlign = "center";
  ctx!.fillText("Game", w / 2, h / 2);
  x = clamp(w / 2 + Math.sin(t / 600) * 200, 0, w);
  ctx!.beginPath();
  ctx!.arc(x, h / 2 + 60, 8, 0, Math.PI * 2);
  ctx!.fill();
  requestAnimationFrame(frame);
}
// 書体の読み込みを待つ（読めなくても、2秒で予備の書体のまま始める）
Promise.race([document.fonts.load(`700 48px ${JP_FONT}`), new Promise((r) => setTimeout(r, 2000))])
  .catch(() => undefined)
  .then(() => requestAnimationFrame(frame));
