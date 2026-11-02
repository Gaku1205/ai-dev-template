#!/usr/bin/env python3
"""工場：デザイン担当（AI）が作った画面（SITE_DIR の src/ と public/）を、新しいリポジトリ（引数のフォルダ）に入れる。

factory.sh が呼ぶ。AIが書いた物なので、決まった形の物だけを入れる。
- src/：全部が決まった形でなければ、1つも入れない（一部だけ入れると、ビルドが壊れるため）。
  名前は英数字と . _ - @ ( ) [ ] だけ（. で始まるフォルダ・.. は不可。. で始まるファイル（.gitkeep など）は黙って飛ばす）、拡張子は決まった物、1つ 300KB・合わせて 400 個・4MB まで。
  入口（SITE_ENTRY。既定 src/app/page.tsx、ゲームは src/main.ts）が要る。入れるときは、テンプレートの src/ を置き換える
- index.html（ゲームの入口。SITE_DIR の直下にあれば）：100KB までの HTML なら、リポジトリの直下に入れる
- public/：形が違う物は飛ばす。1つ 10MB・合わせて 150 個・60MB まで。
  public/photos/ の写真は、src/ のどこかで名前が使われている物だけ（使わない写真は入れない）。CREDITS.md はその写真の行だけ残す
- リンク（シンボリックリンク）は入れない
成功したら、入れた物の数を1行で出して 0 で終わる。入れなかったら、理由を出して 1 で終わる。
"""
import os
import re
import shutil
import sys

SITE = os.environ.get("SITE_DIR", "")
ENTRY = os.environ.get("SITE_ENTRY", "src/app/page.tsx")
DEST = sys.argv[1] if len(sys.argv) > 1 else "."
SEG = re.compile(r"^[A-Za-z0-9_@()\[\]-][A-Za-z0-9._@()\[\]-]{0,79}$")
SRC_EXT = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".css", ".json", ".md", ".svg", ".glsl", ".frag", ".vert", ".wgsl"}
PUB_EXT = {".png", ".jpg", ".jpeg", ".webp", ".avif", ".gif", ".svg", ".ico", ".mp4", ".webm", ".woff", ".woff2",
           ".glb", ".gltf", ".bin", ".hdr", ".ktx2", ".txt", ".md", ".json", ".webmanifest"}


def walk(root):
    """root の下のファイルを (相対パス, 実パス) で返す。リンクは ('link', 相対パス) として返す"""
    out = []
    for d, dirs, files in os.walk(root, followlinks=False):
        for name in list(dirs):
            if os.path.islink(os.path.join(d, name)):
                out.append(("link", os.path.relpath(os.path.join(d, name), root)))
                dirs.remove(name)
        for name in files:
            full = os.path.join(d, name)
            rel = os.path.relpath(full, root)
            out.append(("link" if os.path.islink(full) else "file", rel))
    return sorted(out)


def ok_path(rel, exts):
    parts = rel.split(os.sep)
    if not all(SEG.match(p) for p in parts):
        return False
    return os.path.splitext(rel)[1].lower() in exts


def die(msg):
    print(msg)
    sys.exit(1)


src = os.path.join(SITE, "src")
if not SITE or not os.path.isdir(src) or os.path.islink(src) or os.path.islink(SITE):
    die("src/ がありません")
if not ENTRY.startswith("src/") or ".." in ENTRY or not os.path.isfile(os.path.join(SITE, ENTRY)):
    die(f"{ENTRY} がありません")
src_files, total = [], 0
for kind, rel in walk(src):
    if kind == "link":
        die(f"src/{rel} はリンクです")
    # .gitkeep・.DS_Store など、. で始まるファイルは黙って飛ばす（テンプレートの空フォルダの印など）
    if os.path.basename(rel).startswith("."):
        continue
    if not ok_path(rel, SRC_EXT):
        die(f"src/{rel} は入れられない名前か種類です")
    size = os.path.getsize(os.path.join(src, rel))
    if size > 300 * 1024:
        die(f"src/{rel} が大きすぎます（300KB まで）")
    total += size
    src_files.append(rel)
if len(src_files) > 400 or total > 4 * 1024 * 1024:
    die("src/ のファイルが多すぎるか、大きすぎます（400 個・4MB まで）")

# src の中身（写真の名前が使われているかを見る）
src_text = ""
for rel in src_files:
    with open(os.path.join(src, rel), encoding="utf-8", errors="ignore") as f:
        src_text += f.read()

pub = os.path.join(SITE, "public")
pub_files, pub_total, skipped, photos = [], 0, 0, []
if os.path.isdir(pub) and not os.path.islink(pub):
    for kind, rel in walk(pub):
        if kind == "link" or not ok_path(rel, PUB_EXT):
            skipped += 1
            continue
        parts = rel.split(os.sep)
        if parts[0] == "photos" and rel != os.path.join("photos", "CREDITS.md"):
            if parts[-1] not in src_text:
                continue
            photos.append(parts[-1])
        size = os.path.getsize(os.path.join(pub, rel))
        if size > 10 * 1024 * 1024 or len(pub_files) >= 150 or pub_total + size > 60 * 1024 * 1024:
            skipped += 1
            continue
        pub_total += size
        pub_files.append(rel)

# 入れる：src/ は置き換える。public/ は足す
dest_src = os.path.join(DEST, "src")
shutil.rmtree(dest_src, ignore_errors=True)
for rel in src_files:
    os.makedirs(os.path.dirname(os.path.join(dest_src, rel)), exist_ok=True)
    shutil.copyfile(os.path.join(src, rel), os.path.join(dest_src, rel))
for rel in pub_files:
    target = os.path.join(DEST, "public", rel)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    if rel == os.path.join("photos", "CREDITS.md"):
        with open(os.path.join(pub, rel), encoding="utf-8", errors="ignore") as f:
            lines = f.read().splitlines()
        keep = [l for l in lines if l.startswith("#") or not l.strip() or any(f"`{p}`" in l for p in photos)]
        if photos:
            with open(target, "w", encoding="utf-8") as f:
                f.write("\n".join(keep) + "\n")
        continue
    shutil.copyfile(os.path.join(pub, rel), target)

index = os.path.join(SITE, "index.html")
if os.path.isfile(index) and not os.path.islink(index) and os.path.getsize(index) <= 100 * 1024:
    shutil.copyfile(index, os.path.join(DEST, "index.html"))

summary = f"画面のファイル {len(src_files)} 個"
if photos:
    summary += f"・写真 {len(photos)} 枚（CC0・パブリックドメイン、出どころは public/photos/CREDITS.md）"
other = len([r for r in pub_files if not r.startswith("photos" + os.sep)])
if other:
    summary += f"・ほかの素材 {other} 個"
if skipped:
    summary += f"・形が違うので入れなかった素材 {skipped} 個"
print(summary)
