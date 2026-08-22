# -*- coding: utf-8 -*-
"""把 NotoSansSC 全量 OTF 子集化为「GB2312 一级字库 + ASCII + 中文标点 + app 实际用字」。
8.3MB CFF 全量字体在 CanvasKit(wasm 光栅线程)首次排版中文时解析极慢，卡死首帧。"""
import os
import subprocess
import sys

SRC = r"D:\code\bead_studio\assets\fonts"
LIB = r"D:\code\bead_studio\lib"

# 1) 基础字符集：ASCII 可打印 + 常用中英文标点 + 全角符号
chars = set()
chars.update(chr(c) for c in range(0x20, 0x7F))
chars.update("、。，！？：；﹔…—·ˉ¨‘’“”々～‖∶＂＇｀｜〃〔〕〈〉《》「」『』．〖〗【】（）［］｛｝！？％＋－／＝＄￥Ｆ℃")
chars.update("□■○●△▲◎☆★◇◆■℃㎜①②③④⑤⑥⑦⑧⑨⑩")

# 2) GB2312 一级字库（3755 个常用汉字，0xB0A1-0xD7F9 区）
for hi in range(0xB0, 0xD8):
    for lo in range(0xA1, 0xFF):
        try:
            chars.add(bytes([hi, lo]).decode("gb2312"))
        except UnicodeDecodeError:
            pass

# 3) app 源码里实际出现的所有字符（兜底覆盖一二级库外的用字）
for root, _dirs, files in os.walk(LIB):
    for f in files:
        if f.endswith(".dart"):
            with open(os.path.join(root, f), encoding="utf-8") as fh:
                chars.update(fh.read())

charset = "".join(sorted(c for c in chars if not c.isspace() or c == " "))
charfile = os.path.join(SRC, "_subset_chars.txt")
with open(charfile, "w", encoding="utf-8") as fh:
    fh.write(charset)
print(f"charset size: {len(charset)}")

for name in ["NotoSansSC-Regular", "NotoSansSC-Bold"]:
    src = os.path.join(SRC, name + ".otf")
    dst = os.path.join(SRC, name + ".min.otf")
    r = subprocess.run([
        sys.executable, "-m", "fontTools.subset", src,
        "--text-file=" + charfile,
        "--output-file=" + dst,
        "--layout-features=*",
        "--no-hinting",
        "--desubroutinize",
    ], capture_output=True, text=True)
    if r.returncode != 0:
        print(name, "FAILED:", r.stdout, r.stderr)
        sys.exit(1)
    print(f"{name}: {os.path.getsize(src)//1024}KB -> {os.path.getsize(dst)//1024}KB")
