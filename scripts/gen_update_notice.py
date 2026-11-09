# -*- coding: utf-8 -*-
"""「豆田」v0.2.0 更新公告长图生成器(版式 v4)
用法: python scripts/gen_update_notice.py  -> dist/更新公告_v0.2.0.png
版式: 图纸格纹理头图 + 大图标(标题与徽标上下拉开) / 定名卡 / 亮点数据块
(大字+完整说明) / 五个功能卡(编号章 + 双列小卡条目, emoji 图标);
不放安装说明。模板规矩固化于 .claude/skills/update-notice.md。
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_app_icon as g

ROOT = g.ROOT
W, MARGIN = 2160, 96
INNER = W - 2 * MARGIN
PAD = 70
F = lambda sz, bold=False: ImageFont.truetype(
    os.path.join(ROOT, 'assets', 'fonts',
                 'NotoSansSC-Bold.otf' if bold else 'NotoSansSC-Regular.otf'), sz)
# 小卡条目图标:Windows 自带 Segoe UI Emoji,embedded_color=True 出彩色
EMOJI = lambda sz: ImageFont.truetype('C:/Windows/Fonts/seguiemj.ttf', sz)

BG = (245, 243, 238)
CARD, CARD_BD = (255, 255, 255), (228, 224, 216)
INK, SUB = (43, 42, 38), (120, 116, 106)
RED = (206, 84, 72)
GREEN = (86, 148, 74)
GREEN_SOFT = (123, 182, 97)
GREEN_PALE = (238, 246, 234)
TILE_BG = (242, 245, 239)
TILE_BD = (224, 232, 222)
GRID_LINE = (236, 232, 222)

H_FS, B_FS = 46, 40          # 小卡标题/正文字号
H_LH, B_LH = 56, 56

STATS = [
    ('更快速', '6K 超大原图完整识别', '以前一分多钟还可能崩'),
    ('自定义显示', '复核每行列数随手调', '多看几格 / 看清格内字'),
    ('无损', '抖音图文导入变原图', '和作者上传的一样清楚'),
    ('免登录', '小红书 / 抖音链接导入', '粘贴链接直接拿原图'),
]

FEATURES = [
    ('01', '识别更准了', [
        ('🧹', '空白格不虚涨', '图纸外的空白格直接算空白，印了色号的白豆一颗不丢'),
        ('🔍', '漏读自动补认', '太小、压线的字逐格裁出放大再读，认出色号按色号来'),
    ]),
    ('02', '大图识别又快又稳', [
        ('⚡', '不再卡死崩溃', '超大原图不再放大出上亿像素中间图，自动控制规模'),
        ('📊', '全程进度可见', '进行到哪一步、已确认多少格，一眼可见不用干等'),
    ]),
    ('03', '复核更省力了', [
        ('🖐', '整片拖选', '按住半秒锁定，起点拖到终点一次选中，贴边自动滚屏'),
        ('🔢', '每行 2~16 格', '列表里没有的数字点「自定义」直接输'),
        ('🧮', '共 N 颗徽标', '图例右侧实时总数，和图纸标注一眼对账'),
        ('🔒', '识别中锁定画面', '防止中途误碰改动导致认错位'),
    ]),
    ('04', '导入的图更清楚了', [
        ('🖼', '抖音变原图', '和作者上传的完全一样清楚，免登录、操作不变'),
        ('🔗', '小红书更稳', '链接粘贴修复，大图放大更清楚'),
    ]),
    ('05', '拼豆入口更顺手了', [
        ('🗂', '开始拼豆先选豆板', '缩略图、件数、保存时间一目了然，可重命名 / 删除 / 新建'),
        ('🎚', '对齐步长档 0.01~1', '格子大小与上下左右微调统一按当前档位走'),
        ('🛡', '链接导入防误触', '解析、下载期间面板锁定，不怕误关中断'),
    ]),
]


def adaptive_circle(size, frac=0.72):
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


def full_icon(size):
    return g.masked_icon(g.ARTS['M']('full'), size, 'rounded')


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


def tile_h(body, tw):
    n = len(wrap(body, F(B_FS), tw - 2 * 30))
    return 30 + H_LH + 14 + n * B_LH + 30


def feature_card_h(items):
    tw = (INNER - 2 * PAD - 36) // 2
    h = PAD + 64 + 46
    rows = [(items[i:i + 2]) for i in range(0, len(items), 2)]
    for row in rows:
        span = len(row) == 1 and len(items) % 2 == 1 and row is rows[-1]
        w = INNER - 2 * PAD if span else tw
        h += max(tile_h(it[2], w) for it in row) + 24
    return h - 24 + PAD


def draw_feature(d, board, y, no, title, items):
    ch = feature_card_h(items)
    d.rounded_rectangle([MARGIN, y, W - MARGIN, y + ch], radius=28, fill=CARD,
                        outline=CARD_BD, width=2)
    cx0, cy0 = MARGIN + PAD, y + PAD
    d.rounded_rectangle([cx0, cy0, cx0 + 64, cy0 + 64], radius=16, fill=GREEN)
    d.text((cx0 + 32, cy0 + 32), no, font=F(36, True), fill=(255, 255, 255), anchor='mm')
    d.text((cx0 + 96, cy0 + 2), title, font=F(60, True), fill=INK)
    ty = cy0 + 64 + 46
    tw = (INNER - 2 * PAD - 36) // 2
    rows = [(items[i:i + 2]) for i in range(0, len(items), 2)]
    for ri, row in enumerate(rows):
        span = len(row) == 1 and len(items) % 2 == 1 and ri == len(rows) - 1
        w = INNER - 2 * PAD if span else tw
        rh = max(tile_h(it[2], w) for it in row)
        for ci, (em, head, body) in enumerate(row):
            x0 = cx0 + (0 if span else ci * (tw + 36))
            d.rounded_rectangle([x0, ty, x0 + w, ty + rh], radius=20,
                                fill=TILE_BG, outline=TILE_BD, width=2)
            d.text((x0 + 56, ty + 56), em, font=EMOJI(40), anchor='mm',
                   embedded_color=True)
            d.text((x0 + 94, ty + 30), head, font=F(H_FS, True), fill=INK)
            for li, ln in enumerate(wrap(body, F(B_FS), w - 2 * 30)):
                d.text((x0 + 30, ty + 30 + H_LH + 14 + li * B_LH), ln, font=F(B_FS), fill=SUB)
        ty += rh + 24
    return ch


def measure():
    h = 700 + 46 + 350 + 46 + 330
    for no, title, items in FEATURES:
        h += 46 + feature_card_h(items)
    return h + 80


def draw_board():
    H = measure()
    board = Image.new('RGB', (W, H), BG)
    d = ImageDraw.Draw(board)
    # ---------- 头图(标题与徽标上下拉开,防遮挡) ----------
    hero_h = 700
    for p in range(0, W, 96):
        d.line([(p, 0), (p, hero_h)], fill=GRID_LINE, width=3)
        d.line([(0, p), (W, p)], fill=GRID_LINE, width=3)
    icon = adaptive_circle(330)
    board.paste(icon, (W // 2 - 165, 66), icon)
    d.text((W // 2, 428), '豆田  v0.2.0', font=F(96, True), fill=INK, anchor='ma')
    badge = '大版本更新 · 15 项改进 · 2026-11-09'
    bw = F(42, True).getlength(badge) + 108
    d.rounded_rectangle([W // 2 - bw // 2, 578, W // 2 + bw // 2, 654], radius=38,
                        fill=(255, 255, 255), outline=GREEN_SOFT, width=3)
    d.text((W // 2, 616), badge, font=F(42, True), fill=GREEN, anchor='mm')
    y = hero_h
    # ---------- 定名卡 ----------
    ch = 350
    d.rounded_rectangle([MARGIN, y, W - MARGIN, y + ch], radius=28, fill=CARD,
                        outline=CARD_BD, width=2)
    ic = full_icon(230)
    board.paste(ic, (MARGIN + PAD, y + 60), ic)
    tx = MARGIN + PAD + 230 + 80
    d.text((tx, y + 62), '定名「豆田」，有了自己的图标', font=F(62, True), fill=INK)
    for i, t in enumerate(['「拼豆图案工作室」正式定名「豆田」——豆子的田，名称全部统一。',
                           '全新图标「图纸格豆苗」：绿色豆苗 + 拼豆图纸格子底纹，简单好认。',
                           '安装这次更新后，桌面图标自动换新。']):
        d.text((tx, y + 170 + i * 58), t, font=F(42), fill=SUB)
    y += ch + 46
    # ---------- 亮点数据块 ----------
    tw = (INNER - 3 * 36) // 4
    for i, (num, l1, l2) in enumerate(STATS):
        x0 = MARGIN + i * (tw + 36)
        d.rounded_rectangle([x0, y, x0 + tw, y + 330], radius=28, fill=CARD,
                            outline=CARD_BD, width=2)
        d.rounded_rectangle([x0 + 20, y + 20, x0 + tw - 20, y + 26], radius=3, fill=GREEN_PALE)
        d.rounded_rectangle([x0 + tw // 2 - 70, y + 24, x0 + tw // 2 + 70, y + 30],
                            radius=3, fill=GREEN_SOFT)
        d.text((x0 + tw // 2, y + 118), num, font=F(84, True), fill=GREEN, anchor='mm')
        d.text((x0 + tw // 2, y + 196), l1, font=F(38, True), fill=INK, anchor='ma')
        d.text((x0 + tw // 2, y + 258), l2, font=F(34), fill=SUB, anchor='ma')
    y += 330 + 46
    # ---------- 功能卡 ----------
    for no, title, items in FEATURES:
        y += draw_feature(d, board, y, no, title, items) + 46
    out = os.path.join(ROOT, 'dist', '更新公告_v0.2.0.png')
    board.save(out)
    print('NOTICE ->', out, board.size)


if __name__ == '__main__':
    draw_board()
