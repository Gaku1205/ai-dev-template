# 部品の作り方（写して使う。全部、実際にオーナーの判定を通った実装から抜いたもの）

どれも依存パッケージなし。素の HTML / CSS / WebGL / canvas で動く。Next.js では `"use client"` のコンポーネントに入れ、`useEffect` の中で初期化し、クリーンアップで `cancelAnimationFrame` する。

## 0. ページの骨組み（トークン → 全面の映像 → 浮く文字と操作）

```html
<style>
/* 設計表：この :root が設計そのもの。ここにない色・フォントは使わない */
:root{
  --ground:#0D0F14;  /* 地（夜）。明るい題材なら #F3F3F0 */
  --ink:#ECE8DF;     /* 文字 */
  --mute:rgba(236,232,223,.55);
  --hair:rgba(236,232,223,.12);
  --signal:#5B7CFF;  /* 強い色は1〜2色まで */
  --jp:"IBM Plex Sans JP","Geist",system-ui,sans-serif;
  --latin:"Geist","IBM Plex Sans JP",system-ui,sans-serif;
  --mark:"Syne","Geist",sans-serif;           /* または "Bricolage Grotesque" */
  --ease:cubic-bezier(.2,.8,.2,1);
}
html,body{height:100%}
body{margin:0;background:var(--ground);color:var(--ink);font-family:var(--jp);-webkit-font-smoothing:antialiased;word-break:auto-phrase}
canvas.bg{position:fixed;inset:0;width:100%;height:100%;display:block}      /* 映像（下の層） */
canvas.fg{position:fixed;inset:0;width:100%;height:100%;display:block;z-index:2;pointer-events:none} /* 粒・線（上の層。ぼかしの板の下に置かない） */
:focus-visible{outline:2px solid var(--ink);outline-offset:3px}
</style>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Syne:wght@700;800&family=Geist:wght@400;500;600&family=IBM+Plex+Sans+JP:wght@400;500;700&display=swap">
```

層の順番（下から）：地の色 → 映像の canvas → ぼかしの板（文字の後ろ） → 粒や線の canvas → 文字・操作。

## 1. 巨大な数字と小さな単位

```html
<div class="num"><span id="n">99</span><small>%</small></div>
<style>
.num{display:flex;align-items:baseline;font:600 clamp(96px,18vw,230px)/.82 var(--latin);letter-spacing:-.07em;font-variant-numeric:tabular-nums}
.num small{font:500 clamp(18px,2.4vw,30px) var(--latin);letter-spacing:-.01em;color:var(--mute);margin-left:.18em}
</style>
```
数字が変わるときは、値をばねで追従させて毎フレーム書き換える（下の 6 を使う）。

## 2. 巨大なワードマークを背景に敷く（小さいタイトル＋説明文の代わり）

```html
<div class="mark" aria-hidden="true">KASUMI</div>
<style>
.mark{position:fixed;right:-.1em;top:-.18em;font:800 min(24vw,36vh)/.8 var(--mark);letter-spacing:-.05em;color:var(--ink);opacity:.045;pointer-events:none;user-select:none;white-space:nowrap}
/* 明るい地に映像があるときは、乗算で溶かす */
/* .mark{mix-blend-mode:multiply;opacity:1;color:#E2E1D9} */
@media (max-width:760px){.mark{font-size:34vw;top:-.12em}}
</style>
```
置く場所は、文字や名札のない隅。見出しの `h1` は別に、視覚的に隠して残す（スクリーンリーダー用）。

## 3. 文字の後ろだけすりガラス、端は消す（白い板で画面を分けない）

```css
.copy{position:fixed;left:0;top:0;bottom:0;width:min(46%,620px);box-sizing:border-box;padding:84px 64px 36px max(40px,env(safe-area-inset-left,0px));z-index:3;
  background:color-mix(in srgb,var(--ground) 38%,transparent);
  -webkit-backdrop-filter:blur(30px) saturate(1.35);backdrop-filter:blur(30px) saturate(1.35);
  -webkit-mask-image:linear-gradient(90deg,#000 0,#000 72%,transparent 100%);mask-image:linear-gradient(90deg,#000 0,#000 72%,transparent 100%)}
@media (max-width:760px){
  .copy{width:100%;bottom:auto;padding:64px 20px 34px;-webkit-mask-image:linear-gradient(180deg,#000 0,#000 78%,transparent 100%);mask-image:linear-gradient(180deg,#000 0,#000 78%,transparent 100%)}
}
```
この板の下に、粒や線を置かない（ぼけて太さが変わり「急にズームした」ように見える）。粒や線は `canvas.fg` に描く。

## 4. 画面の端の名札（目盛りつき）

```html
<aside class="edge" aria-label="…">
  <div class="tag on"><div class="t">Top</div><div class="m">柚子、ベルガモット</div><i class="tick"></i></div>
  <div class="tag"><div class="t">Heart</div><div class="m">白茶、スズラン</div><i class="tick"></i></div>
</aside>
<style>
.edge{position:fixed;right:max(28px,env(safe-area-inset-right,0px));top:50%;transform:translateY(-50%);width:210px;display:flex;flex-direction:column;gap:38px;z-index:2;text-align:right}
.tag{display:grid;grid-template-columns:1fr 26px;column-gap:10px;align-items:start;opacity:.38;transition:opacity .5s var(--ease)}
.tag.on{opacity:1}
.tag .t,.tag .m{grid-column:1}              /* ← 列を明示しないと、本文が 26px の列に入って縦に崩れる */
.tag .t{font:600 13px var(--latin);letter-spacing:.02em}
.tag .m{font:400 13px/1.55 var(--jp);color:var(--mute);margin-top:3px}
.tag .tick{grid-column:2;grid-row:1;margin-top:8px;height:1px;background:var(--ink);opacity:.5;transform-origin:right;transition:transform .5s var(--ease)}
.tag.on .tick{transform:scaleX(1.6)}
@media (max-width:760px){.edge{right:16px;top:auto;bottom:132px;transform:none;gap:16px;width:170px}}
</style>
```
名札の文字は1語（`Top` `Boundary` `Unknown`）。数を添えるなら小さく（`Orange 46`）。canvas の中に描く名札も同じ：端に置き、端から目盛りを内側へ、対象へは点線。

## 5. 日本語の本文は、意味の区切りでだけ折る

```js
el.innerHTML = text.split(/(?<=[、。])/).filter(Boolean).map(s => `<span>${s}</span>`).join('');
```
```css
.now span{display:inline-block}
```
見出しの2行は `<span>` ごとに `display:block;white-space:nowrap` で固定する。

## 6. ばね（動きは全部これで。時間でイージングしない）

```js
// 1次元。k=剛性, c=減衰。画面の値は k 300〜500 / c 25〜35、色や位置の追従は k 24〜140 / c 9〜20
function spring(s, target, dt, k = 300, c = 28) { s.v += (k * (target - s.x) - c * s.v) * dt; s.x += s.v * dt; return s.x; }
// 使い方
const acc = { x: 0, v: 0 };
function frame(now) { const dt = Math.min(.05, (now - last) / 1000); last = now;
  el.textContent = Math.round(spring(acc, targetValue, dt));
  requestAnimationFrame(frame); }
```
`prefers-reduced-motion: reduce` のときは `s.x = target` で即座に合わせる。

## 7. 粒子の霧（WebGL 点スプライト。暗い地は加算、明るい地は通常合成）

要点：丸い点だけ（四角を描かない）。流れは**ノイズの curl**（発散しない。これをしないと粒が溝に集まって線になる）。大きな薄い靄＋小さな粒の2層。スマホは粒を 1/3。

```js
const cv = document.querySelector('canvas.bg'), gl = cv.getContext('webgl', { antialias: false, alpha: false });
const mobile = innerWidth < 760, N_FOG = mobile ? 180 : 360, N_DROP = mobile ? 3200 : 9000, N = N_FOG + N_DROP;
const vs = `attribute vec2 p;attribute float s;attribute float a;attribute vec3 w;varying float va;varying vec3 vc;
uniform vec2 R;uniform float DPR;uniform float T;uniform float SC;uniform vec3 A;uniform vec3 B;uniform vec3 C;
void main(){vec2 q=vec2(p.x/(R.x/R.y),p.y);gl_Position=vec4(q*2.-1.,0.,1.);
  float tw=.85+.15*sin(T*1.7+w.z*40.);gl_PointSize=s*DPR*SC*tw;vc=mix(mix(A,B,w.x),C,w.y*.8);va=a;}`;
const fs = `precision mediump float;varying float va;varying vec3 vc;uniform float LIGHT;
void main(){float d=length(gl_PointCoord-.5);float f=smoothstep(.5,.08,d);gl_FragColor=vec4(vc,f*va*(1.+LIGHT*1.3));}`;
const sh=(t,s)=>{const o=gl.createShader(t);gl.shaderSource(o,s);gl.compileShader(o);if(!gl.getShaderParameter(o,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(o));return o;};
const prog=gl.createProgram();gl.attachShader(prog,sh(gl.VERTEX_SHADER,vs));gl.attachShader(prog,sh(gl.FRAGMENT_SHADER,fs));gl.linkProgram(prog);gl.useProgram(prog);
const U={};for(const k of ['R','DPR','T','SC','A','B','C','LIGHT'])U[k]=gl.getUniformLocation(prog,k);
const maxPS=(gl.getParameter(gl.ALIASED_POINT_SIZE_RANGE)||[1,64])[1];
let W=1,H=1,AR=1,DPR=1;
function size(){DPR=Math.min(2,devicePixelRatio||1);W=cv.width=Math.round(innerWidth*DPR);H=cv.height=Math.round(innerHeight*DPR);AR=W/H;gl.viewport(0,0,W,H);}
size();addEventListener('resize',size);
const px=new Float32Array(N),py=new Float32Array(N),vx=new Float32Array(N),vy=new Float32Array(N),sz=new Float32Array(N),al=new Float32Array(N),wt=new Float32Array(N*3),pos=new Float32Array(N*2);
for(let i=0;i<N;i++){px[i]=Math.random()*2;py[i]=Math.random();const fog=i<N_FOG;
  sz[i]=fog?Math.min(maxPS,90+Math.random()*90):3+Math.pow(Math.random(),2.2)*15;al[i]=fog?.035:.10+Math.random()*.12;
  wt[i*3]=Math.random();wt[i*3+1]=Math.random()*Math.random();wt[i*3+2]=Math.random();}
function attr(n,d,c){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,d,gl.STATIC_DRAW);const l=gl.getAttribLocation(prog,n);gl.enableVertexAttribArray(l);gl.vertexAttribPointer(l,c,gl.FLOAT,false,0,0);}
attr('s',sz,1);attr('a',al,1);attr('w',wt,3);
const posBuf=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,posBuf);gl.bufferData(gl.ARRAY_BUFFER,pos,gl.DYNAMIC_DRAW);
const lp=gl.getAttribLocation(prog,'p');gl.enableVertexAttribArray(lp);gl.vertexAttribPointer(lp,2,gl.FLOAT,false,0,0);gl.enable(gl.BLEND);
// 流れ：小さな格子の値ノイズ（5次補間。3次だと格子の線が見える）
const GS=64,grid=new Float32Array(GS*GS);for(let i=0;i<grid.length;i++)grid[i]=Math.random();
function vnoise(x,y){x=((x%GS)+GS)%GS;y=((y%GS)+GS)%GS;const x0=x|0,y0=y|0,x1=(x0+1)%GS,y1=(y0+1)%GS,fx=x-x0,fy=y-y0,
  ux=fx*fx*fx*(fx*(fx*6-15)+10),uy=fy*fy*fy*(fy*(fy*6-15)+10);const a=grid[y0*GS+x0],b=grid[y0*GS+x1],c=grid[y1*GS+x0],d=grid[y1*GS+x1];
  const t=a+(b-a)*ux;return t+((c+(d-c)*ux)-t)*uy;}
// stage 0..1：0 は軽く速く上へ、1 は重く遅く下へ。stir はポインタの速さ、(mx,my) は 0..1（y は下が 0）
function step(dt,T,stage,stir,mx,my){const speed=.07-.045*stage,lift=.02-.045*stage,k=5.5,sx=1.6+T*.018,sy=-T*.012,mX=mx*AR,mY=my;
  for(let i=0;i<N;i++){const f=i<N_FOG?.45:1,nx0=px[i]*k+sx,ny0=py[i]*k+sy,e=.35,n0=vnoise(nx0,ny0);
    const cx=(vnoise(nx0,ny0+e)-n0)/e,cy=-(vnoise(nx0+e,ny0)-n0)/e;   // curl
    let ax=cx*speed*f+(Math.random()-.5)*.03,ay=cy*speed*f+lift*f+(Math.random()-.5)*.03;
    if(stir>.001){const dx=px[i]-mX,dy=py[i]-mY,r2=dx*dx+dy*dy;if(r2<.12){const g=stir*Math.exp(-r2*24)*.9;ax+=(-dy*g+dx*g*.35);ay+=(dx*g+dy*g*.35);}}
    vx[i]+=(ax-vx[i])*Math.min(1,dt*2.2);vy[i]+=(ay-vy[i])*Math.min(1,dt*2.2);
    let x=px[i]+vx[i]*dt,y=py[i]+vy[i]*dt;if(x<-.05)x+=AR+.1;else if(x>AR+.05)x-=AR+.1;if(y<-.05)y+=1.1;else if(y>1.05)y-=1.1;
    px[i]=x;py[i]=y;pos[i*2]=x;pos[i*2+1]=y;}
  gl.bindBuffer(gl.ARRAY_BUFFER,posBuf);gl.bufferSubData(gl.ARRAY_BUFFER,0,pos);}
// ground/A/B/C は [r,g,b] 0..1。light=true は明るい地（通常合成・色は地より濃く）
function render(ground,A,B,C,T,stage,light){gl.clearColor(ground[0],ground[1],ground[2],1);gl.clear(gl.COLOR_BUFFER_BIT);
  if(light)gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);else gl.blendFunc(gl.SRC_ALPHA,gl.ONE);
  gl.uniform2f(U.R,W,H);gl.uniform1f(U.DPR,DPR);gl.uniform1f(U.T,T);gl.uniform1f(U.SC,1+.9*stage);gl.uniform1f(U.LIGHT,light?1:0);
  gl.uniform3fv(U.A,A);gl.uniform3fv(U.B,B);gl.uniform3fv(U.C,C);gl.drawArrays(gl.POINTS,0,N);}
// ポインタ：stir = min(2.2, stir + 移動量*14)、毎フレーム stir -= dt*1.6
```
色は題材で決める。暗い地の例：夜 `#0A0B10` に `#8FA4FF #E6ECFF #3B4A8A`。明るい地の例：`#EFEDE6` に `#A9C23E #EE9460 #CFDB8A`（明るい地の粒は、地より濃い色でないと見えない）。

## 8. 色の場（連続した色。境界が流れて変わる）

フラグメントシェーダーで fbm ノイズ＋ドメインワープ。柔らかい霧にするなら周波数は低く（`p*0.55〜0.7`）、ワープは弱く（`0.8〜0.9`）、4オクターブ。解像度は 0.5〜0.6 倍で描いて引き伸ばす（引き伸ばしで更に柔らかくなる）。

```glsl
precision highp float;varying vec2 uv;
uniform vec2 R;uniform float T;uniform vec2 M;uniform float ST;uniform vec3 G;uniform vec3 A;uniform vec3 B;uniform vec3 C;
// snoise：2D simplex（定番の実装をそのまま入れる）
float fbm(vec2 p){float v=0.,a=.55;for(int i=0;i<4;i++){v+=a*snoise(p);p=p*1.9+vec2(1.7,9.2);a*=.48;}return v;}
void main(){
  vec2 p=vec2(uv.x*R.x/R.y,uv.y);
  vec2 m=vec2(M.x*R.x/R.y,M.y);vec2 d=p-m;float r=length(d);float ang=ST*exp(-r*r*7.);     // かき混ぜ：ポインタ周りで回転
  float cs=cos(ang),sn=sin(ang);p=m+vec2(d.x*cs-d.y*sn,d.x*sn+d.y*cs);
  float t=T*.6;
  vec2 q=vec2(fbm(p*.55+vec2(0.,t*.05)),fbm(p*.55+vec2(5.2,1.3)-t*.04));
  vec2 w=vec2(fbm(p*.6+.8*q+vec2(1.7,9.2)+t*.025),fbm(p*.6+.8*q+vec2(8.3,2.8)-t*.03));
  float n=fbm(p*.7+.9*w),n2=fbm(p*1.4-.8*w+vec2(3.1,7.7));
  float dens=smoothstep(-.65,.75,n+.2*n2);
  vec3 col=mix(A,B,smoothstep(-.6,.6,w.x));col=mix(col,C,smoothstep(-.3,.7,w.y)*.85);
  col=mix(col,vec3(1.),smoothstep(.4,.9,n2)*.14);                       // 薄い所の光
  vec3 o=mix(G,col,dens);
  o+=(fract(sin(dot(gl_FragCoord.xy+T,vec2(12.9898,78.233)))*43758.5453)-.5)*.02; // 縞を消す粒
  gl_FragColor=vec4(o,1.);}
```
2クラスの境界を見せる場（Field Lab）は、点ごとのガウス核の重み付き投票 `score` を計算し、`abs(score)` が 0 に近い所を**細い白い継ぎ目**にする（黒い太線にしない）。`fwidth(score)` で太さを画面に合わせる。

## 9. 内容で部屋ごと変える（地・文字・強い色を一度に）

```css
body[data-theme="yoru"]{--ground:#0A0B10;--ink:#E9ECF5;--mute:rgba(233,236,245,.55);color-scheme:dark}
body{transition:background .9s var(--ease),color .9s var(--ease)}
```
映像の色は JS でばね追従（上の 6）。文字の色の切り替えは CSS の transition に任せる。

## 10. 見直し用の撮影スクリプト（必ず撮る）

```js
// node shot.js  … d-*.png / m-*.png ができる。WebGL は --use-gl=swiftshader で動く
const { chromium } = require('playwright');
(async () => { const b = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist'] });
  const html = require('fs').readFileSync('index.html', 'utf8');
  for (const [w, h, n] of [[1280, 800, 'd'], [400, 820, 'm']]) { const p = await b.newPage({ viewport: { width: w, height: h } });
    const errs = []; p.on('pageerror', e => errs.push(e.message));
    await p.setContent(html); await p.waitForTimeout(2500); await p.screenshot({ path: `${n}-0.png` });
    await p.evaluate(() => scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * .5)); await p.waitForTimeout(1500); await p.screenshot({ path: `${n}-1.png` });
    console.log(n, errs.join(' | ') || 'ok'); }
  await b.close(); })();
```
撮ったら、拡大して「四角・切れ目・残像・全面の縦線・文の途中の改行・端で切れた映像」を探す。

## よくある失敗と直し方

| 症状 | 原因 | 直し方 |
| --- | --- | --- |
| 粒が線や血管のように集まる | 流れに発散がある（角度場） | ノイズの curl を使う（7） |
| 霧が大理石・油のように硬い | ノイズの周波数が高い、ワープが強い | 周波数を下げ、ワープ 0.8〜0.9、4オクターブ、低解像度で描く（8） |
| 粒が四角く見える | `fillRect`／加算のまま塗り重ね | 丸い点、毎フレーム消す、尾は前の位置からの短い線 |
| 端の名札の本文が縦1文字ずつ | grid の列を明示していない | `.t,.m{grid-column:1}` `.tick{grid-column:2;grid-row:1}`（4） |
| 線や粒がぼかしの下で太さが変わる（ズーム感） | ぼかしの板の下に描いている | 別の canvas（上の層）に描く（0, 3） |
| 白い板と映像の硬い境目 | 板に不透明の背景 | 板は半透明＋ぼかし、端を mask で消す（3） |
| 明るい地で粒が見えない | 粒の色が地より薄い | 粒の色を地より濃く、通常合成、alpha ×1.3（7） |
| 映像が画面の端で切れる | データや絵の範囲が端まで | データは枠の内側に収め、映像の色は端まで届かせる |
| 文の途中で改行 | ブラウザ任せ | `、。` で分けた span（5） |
| 全面に長い縦線 | 区切りを線で描いた | 線を消し、必要なら光の柱（上下左右にグラデーションで消える）を一瞬だけ |
