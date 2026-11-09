# -*- coding: utf-8 -*-
"""「豆田」v0.2.0 更新公告长图生成器
用法: python scripts/gen_update_notice.py  -> dist/更新公告_v0.2.0.png
风格与 gen_icon_journey 一致(米底白卡/红绿点缀/Noto Sans SC);
头部为自适应图标(72% 圆遮罩观感)+ 演变三连(A -> J -> M)。
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_app_icon as g

ROOT = g.ROOT
W, MARGIN = 2160, 100
CARD_PAD = 74
F = lambda sz, bold=False: ImageFont.truetype(
    os.path.join(ROOT, 'assets', 'fonts',
                 'NotoSansSC-Bold.otf' if bold else 'NotoSansSC-Regular.otf'), sz)

BG = (245, 243, 238)
CARD, CARD_BD = (255, 255, 255), (228, 224, 216)
INK, SUB = (43, 42, 38), (138, 133, 122)
RED = (206, 84, 72)
GREEN = (86, 148, 74)
GREEN_SOFT = (123, 182, 97)
INSTALL_BG, INSTALL_BD = (238, 246, 234), (191, 224, 166)

BODY, BODY_LH = 46, 78
HEAD, HEAD_SZ = 64, 62


def adaptive_circle(size, frac=0.72):
    """自适应层合成后按圆遮罩裁切(桌面观感)"""
    bg = g.art_M('bg')[..., :3]
    fg = g.art_M('shapes')
    a = fg[..., 3:]
    rgb = np.clip(fg[..., :3] * a + bg * (1 - a), 0, 1)
    img = Image.fromarray((rgb * 255).astype(np.uint8)).resize((size * 2, size * 2), Image.LANCZOS)
    m = Image.new('L', img.size, 0)
    ImageDraw.Draw(m).ellipse([0, 0, img.size[0], img.size[1]], fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(img.resize((size, size), Image.LANCZOS), (0, 0), m)
    return out


def full_icon(key, size):
    return g.masked_icon(g.ARTS[key]('full'), size, 'rounded')


SECTIONS = [
    (RED, '定名「豆田」，有了自己的图标', 'hero', [
        '「拼豆图案工作室」正式定名「豆田」——豆子的田，桌面名称与应用内标题全部统一。',
        '全新图标「图纸格豆苗」：一颗绿豆苗从拼豆图纸的格线里长出来。13 稿、5 轮挑选才定下来：不要抽象渐变、不要圆豆，就要拼豆图纸本来的样子。',
        'Android 桌面上无论圆形还是圆角方形图标槽都自适应，图纸格线无限延伸、边缘自然裁切；安装后桌面图标自动换新。',
    ]),
    (GREEN, '识别更准了', None, [
        '空白格不会再被认成白色豆豆：图纸用到白色、米白色的豆（H2、H1 这类）时，图案外的空白格以前会被成片认成白色，一张图凭空多出几百颗；现在格子里没印字就直接算空白，真正印了色号的白豆一颗不丢。',
        '看漏的字会自动放大再看一遍：字很小或压在格线上的色号，第一遍识别会看漏，现在逐格裁出放大再认一遍——认出印刷色号就按色号来，比猜颜色准得多。',
    ]),
    (GREEN, '大图识别又快又稳', None, [
        '超大原图不再卡死崩溃：以前 6K 级别的小红书原图要先放大出上亿像素的中间图，等一分多钟还可能中途崩掉；现在自动控制放大规模，实测同样大图约 37 秒完整识别 37 色。',
        '识别全程能看到进度：进行到哪一步、已确认多少格，一眼可见，不用干等。',
    ]),
    (GREEN, '复核更省力了', None, [
        '按住拖一下，整片格子一次选中：按住半秒锁定，从起点拖到终点一整片选中/取消，拖到屏幕边上自动滚动接着选。',
        '截图墙每行显示几格可以调（2~16 格）：想一屏多看几格调大，想看清格子里的字就调小；列表里没有的数字点「自定义」直接输。',
        '图例清单右侧常驻「共 N 颗」：改数字立即更新，和图纸标注总数一眼对账。',
        '识别进行中会暂时锁定画面，避免中途误碰导致认错位。',
    ]),
    (GREEN, '导入的图更清楚了', None, [
        '抖音图文导入变成原图：和作者发布的完全一样清楚（以前是被平台压缩过的），放大数格子不再糊；仍免登录、操作不变。',
        '小红书导入修好了链接复制粘贴的小问题，大图放大也更清楚。',
    ]),
    (GREEN, '拼豆入口更顺手了', None, [
        '「开始拼豆」先选豆板：豆板选择页里缩略图、名称、作品数、保存时间一目了然，可重命名、删除、新建空板；还没有豆板时自动进新空板，和以前直达的习惯一致。',
        '九宫格对齐微调加了步长档（0.01 / 0.05 / 0.1 / 0.5 / 1）：「格子大小」和上下左右微移统一按当前档位走。',
        '链接导入防误触：解析、下载期间面板自动锁定，不会误触换图、误关面板导致导入中断。',
    ]),
    (GREEN, '安装说明', 'install', [
        '下载 bead_studio_v0.2.0.apk 直接安装即可（覆盖旧版本），作品和拼豆进度全部保留；安装后桌面会显示新的「豆田」图标。',
    ]),
]


def wrap(text, font, maxw):
    lines, line = [], ''
    for ch in text:
        if font.getlength(line + ch) > maxw:
            lines.append(line)
            line = ch
        else:
            line += ch
    lines.append(line)
    return lines


def bullet_height(texts, inner_w):
    h = 8
    for i, t in enumerate(texts):
        lines = wrap(t, F(BODY), inner_w - 56)
        h += len(lines) * BODY_LH + (26 if i < len(texts) - 1 else 0)
    return h


def measure():
    h = 560                                    # 页眉(图标+标题)
    for color, title, kind, texts in SECTIONS:
        inner_w = W - 2 * MARGIN - 2 * CARD_PAD
        body_h = bullet_height(texts, inner_w)
        extra = 300 if kind == 'hero' else 0
        h += HEAD + 46 + body_h + extra + 2 * CARD_PAD + 56   # 卡片本体 + 段距
    h += 70
    return h


def draw_board():
    H = measure()
    board = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(board)
    # ---------- 页眉 ----------
    icon = adaptive_circle(300)
    board.paste(icon, (W // 2 - 150, 96), icon)
    d.text((W // 2, 452), '豆田 v0.2.0 更新公告', font=F(96, True), fill=INK, anchor='ma')
    d.text((W // 2, 570), '2026-11-09 · 大版本：定名与新图标 + 15 项改进', font=F(44), fill=SUB, anchor='ma')
    y = 660
    # ---------- 各节 ----------
    for color, title, kind, texts in SECTIONS:
        inner_w = W - 2 * MARGIN - 2 * CARD_PAD
        body_h = bullet_height(texts, inner_w)
        hero_h = 300 if kind == 'hero' else 0
        card_h = HEAD + 46 + body_h + hero_h + 2 * CARD_PAD
        if kind == 'install':
            d.rounded_rectangle([MARGIN, y, W - MARGIN, y + card_h], radius=26,
                                fill=INSTALL_BG, outline=INSTALL_BD, width=3)
        else:
            d.rounded_rectangle([MARGIN, y, W - MARGIN, y + card_h], radius=26,
                                fill=CARD, outline=CARD_BD, width=2)
        x0, ty = MARGIN + CARD_PAD, y + CARD_PAD
        d.rounded_rectangle([x0, ty + 8, x0 + 14, ty + HEAD_SZ - 8], radius=7, fill=color)
        d.text((x0 + 44, ty), title, font=F(HEAD_SZ, True), fill=INK)
        ty += HEAD + 46
        if kind == 'hero':
            # 演变三连: A 初稿 -> J 方向 -> M 定稿
            strip_y = ty
            caps = [('初稿 · 九宫豆田', 'A'), ('第 4 稿 · 方豆豆苗', 'J'), ('定稿 · 图纸格豆苗', 'M')]
            cell_w = inner_w // 3
            for i, (cap, key) in enumerate(caps):
                cx = x0 + i * cell_w + cell_w // 2
                ic = adaptive_circle(210) if key == 'M' else full_icon(key, 210)
                board.paste(ic, (cx - 105, strip_y), ic)
                d.text((cx, strip_y + 226), cap, font=F(38), fill=SUB, anchor='ma')
                if i < 2:
                    d.text((x0 + (i + 1) * cell_w - cell_w // 2 + cell_w // 8, strip_y + 88),
                           '→', font=F(64, True), fill=(180, 176, 166), anchor='ma')
            ty += hero_h
        for i, t in enumerate(texts):
            lines = wrap(t, F(BODY), inner_w - 56)
            for li, ln in enumerate(lines):
                if li == 0:
                    d.ellipse([x0 + 6, ty + 26, x0 + 26, ty + 46], fill=GREEN_SOFT)
                d.text((x0 + 56, ty), ln, font=F(BODY), fill=INK)
                ty += BODY_LH
            ty += 26
        y += card_h + 56
    out = os.path.join(ROOT, 'dist', '更新公告_v0.2.0.png')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    board.save(out)
    print('NOTICE ->', out, board.size)


if __name__ == '__main__':
    draw_board()
