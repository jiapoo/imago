"""Imago videos: App Store preview (iPhone footage only) and social versions (EN, 简体).

    python3 build.py <preview|social> <en|zh> <out.mp4>

Needs seg/<lang>-a..d.mp4 (iPhone clips at 30 fps) and the Mac stills in MAC_DIR.
Style matches Elapsa's videos: crimson background, white bold captions, rounded screens.
"""
import os
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

KIND, LANG, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
HERE = os.path.dirname(os.path.abspath(__file__))
SEG = os.path.join(HERE, "seg")
MAC_DIR = "/Volumes/APPS/work/.imago-shots/raw/mac"
ICON = "/Volumes/APPS/market/ljworkshop/site/img/imago/icon-rounded.webp"
L = os.path.join(HERE, f"layers-{KIND}-{LANG}")
os.makedirs(L, exist_ok=True)

CRIMSON, WARM, INK, MUTED = (221, 27, 63), (251, 250, 248), (20, 19, 18), (139, 134, 127)
if KIND == "preview":
    W, H, SX, SY, SW, RAD, CAPC = 886, 1920, 104, 409, 678, 46, 205
else:
    W, H, SX, SY, SW, RAD, CAPC = 1080, 1920, 130, 560, 820, 52, 365
SH = round(2868 * SW / 1320)
SAFE_R = 0 if KIND == "preview" else 140  # keep clear of TikTok/Reels/小红书 side buttons

T = {
    "en": {
        "preview": ["iPhone storage full?\nKeep every photo.",
                    "Backs up to your own Mac\nover your Wi-Fi.",
                    "No cloud. No account.\nNo subscription.",
                    "And every night,\nby itself."],
        "hook": "iPhone storage full?\nDon't pay for\nmore iCloud.",
        "social": ["Back up every photo\nto your own Mac.",
                   "Over your Wi-Fi.\nNo cloud, no account.",
                   "Every photo safe\non your Mac."],
        "mac": ["Your whole library,\nas plain files you keep.",
                "Then free up space:\nduplicates, similar shots."],
        "name": "Imago",
        "cta": "Search “Imago”\non the App Store",
        "small": "Free for 7 days · then one purchase\nWorks with the free Imago Mac app",
    },
    "zh": {
        "hook": "iPhone内存满了？\n不想再买\niCloud 空间",
        "social": ["把照片备份到\n你自己的 Mac",
                   "走家里的 Wi-Fi\n不上云，不注册",
                   "每一张照片\n都存在 Mac 上",
                   "充电时\n夜里自动备份"],
        "mac": ["完整照片库\n都是你自己的文件",
                "再安全地清理\n重复和相似照片"],
        "name": "Imago",
        "cta": "App Store 搜索\n「Imago」",
        "small": "免费试用 7 天 · 一次性买断，不是订阅\n搭配免费的 Imago Mac 版使用",
    },
}[LANG]


def font(size, bold=True):
    if LANG == "zh":
        f = ImageFont.truetype("/System/Library/Fonts/Hiragino Sans GB.ttc", size, index=2 if bold else 0)
    else:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
        try:
            f.set_variation_by_name("Bold" if bold else "Regular")
        except Exception:
            pass
    f._bold = bold
    return f


def centred(d, text, f, cy, fill, spacing):
    max_w = W - 120 - SAFE_R * 2
    size = f.size
    while True:
        b = d.multiline_textbbox((0, 0), text, font=f, align="center", spacing=spacing)
        tw, th = b[2] - b[0], b[3] - b[1]
        if tw <= max_w:
            break
        size -= 2
        f = font(size, f._bold)
    x = (W - SAFE_R - tw) / 2 + SAFE_R / 2 - b[0]
    d.multiline_text((x, cy - th / 2 - b[1]), text, font=f, fill=fill, align="center", spacing=spacing)


def caption(text, path):
    img = Image.new("RGBA", (W, SY), (0, 0, 0, 0))
    centred(ImageDraw.Draw(img), text, font(64 if LANG == "zh" else 62), CAPC, "white", 20)
    img.save(path)


def run(cmd):
    subprocess.run(cmd, check=True)


Image.new("RGB", (W, H), CRIMSON).save(f"{L}/bg.png")
mask = Image.new("L", (SW, SH), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, SW - 1, SH - 1), radius=RAD, fill=255)
mask.save(f"{L}/mask.png")

ENC = ["-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-r", "30"]


def phone_part(clip, text, out):
    """One iPhone clip in a rounded screen on crimson, with its caption."""
    caption(text, f"{L}/cap.png")
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", clip],
                         capture_output=True, text=True, check=True).stdout.strip()
    loop = ["-loop", "1", "-framerate", "30", "-t", dur]
    run(["ffmpeg", "-loglevel", "error", "-y", "-i", clip, *loop, "-i", f"{L}/bg.png", *loop, "-i", f"{L}/mask.png",
         *loop, "-i", f"{L}/cap.png", "-t", dur, "-filter_complex",
         f"[0:v]scale={SW}:{SH}:flags=lanczos,format=rgba[s];[2:v]format=gray[m];[s][m]alphamerge[r];"
         f"[1:v]format=rgba[b];[b][r]overlay={SX}:{SY}:shortest=1[x];"
         f"[3:v]format=rgba,fade=t=in:st=0:d=0.3:alpha=1[c];[x][c]overlay=0:0,format=yuv420p[v]",
         "-map", "[v]", "-an", *ENC, out])


def still_part(png, seconds, out):
    run(["ffmpeg", "-loglevel", "error", "-y", "-loop", "1", "-t", str(seconds), "-i", png,
         "-vf", "fps=30,format=yuv420p", "-an", *ENC, out])


def mac_part(src, text, out, seconds=3.2):
    """A Mac window still, rounded, on crimson, with a slow zoom and its caption."""
    win = Image.open(src).convert("RGB")
    # keep the sidebar and the first photos: a squarer crop reads bigger on a phone
    win = win.crop((0, 0, min(win.width, round(win.height * 1.2)), win.height))
    ww = W - 80
    wh = round(win.height * ww / win.width)
    win = win.resize((ww, wh), Image.LANCZOS)
    m = Image.new("L", (ww, wh), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, ww - 1, wh - 1), radius=22, fill=255)
    frames = int(seconds * 30)
    cap = Image.new("RGBA", (W, SY), (0, 0, 0, 0))
    centred(ImageDraw.Draw(cap), text, font(64 if LANG == "zh" else 62), CAPC, "white", 20)
    fdir = f"{L}/mac-{os.path.basename(out)}"
    os.makedirs(fdir, exist_ok=True)
    for i in range(frames):
        z = 1 + 0.06 * i / frames
        zw, zh = round(ww * z), round(wh * z)
        # crop the zoomed window back to its box, drifting toward the top-left content
        big = win.resize((zw, zh), Image.LANCZOS)
        ox, oy = round((zw - ww) * 0.35), round((zh - wh) * 0.25)
        view = big.crop((ox, oy, ox + ww, oy + wh))
        f = Image.new("RGB", (W, H), CRIMSON)
        top = SY + 80
        sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle((40, top + 18, 40 + ww, top + wh + 18), radius=22, fill=(0, 0, 0, 70))
        f.paste(sh.filter(ImageFilter.GaussianBlur(18)), (0, 0), sh.filter(ImageFilter.GaussianBlur(18)))
        f.paste(view, (40, top), m)
        a = min(1.0, i / 9)
        c = cap.copy()
        c.putalpha(c.getchannel("A").point(lambda p: int(p * a)))
        f.paste(c, (0, 0), c)
        f.save(f"{fdir}/{i:04d}.png")
    run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "30", "-i", f"{fdir}/%04d.png", "-an", *ENC, out])


def hook_card(out):
    img = Image.new("RGB", (W, H), CRIMSON)
    centred(ImageDraw.Draw(img), T["hook"], font(118 if LANG == "zh" else 100), 820, "white", 30)
    img.save(f"{L}/hook.png")
    still_part(f"{L}/hook.png", 2.2, out)


def end_card(out):
    img = Image.new("RGB", (W, H), WARM)
    icon = Image.open(ICON).convert("RGBA").resize((260, 260), Image.LANCZOS)
    ix = (W - SAFE_R - 260) // 2 + SAFE_R // 2
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((ix + 14, 470, ix + 246, 712), radius=58, fill=(20, 19, 18, 70))
    sh = sh.filter(ImageFilter.GaussianBlur(22))
    img.paste(sh, (0, 0), sh)
    img.paste(icon, (ix, 440), icon)
    d = ImageDraw.Draw(img)
    centred(d, T["name"], font(120), 840, INK, 10)
    centred(d, T["cta"], font(70), 1040, CRIMSON, 24)
    centred(d, T["small"], font(40, bold=False), 1260, MUTED, 16)
    img.save(f"{L}/end.png")
    still_part(f"{L}/end.png", 2.8, out)


parts = []
if KIND == "preview":
    for k, text in zip("abcd", T["preview"]):
        p = f"{L}/p-{k}.mp4"
        phone_part(f"{SEG}/{LANG}-{k}.mp4", text, p)
        parts.append(p)
else:
    hook_card(f"{L}/0-hook.mp4")
    parts.append(f"{L}/0-hook.mp4")
    keys = "abc" if LANG == "en" else "abcd"
    for k, text in zip(keys, T["social"]):
        p = f"{L}/p-{k}.mp4"
        phone_part(f"{SEG}/{LANG}-{k}.mp4", text, p)
        parts.append(p)
    lang_dir = "en" if LANG == "en" else "zh-Hans"
    for name, text in zip(["2-library", "4-similar"], T["mac"]):
        p = f"{L}/m-{name}.mp4"
        mac_part(f"{MAC_DIR}/{lang_dir}-{name}.png", text, p)
        parts.append(p)
    end_card(f"{L}/9-end.mp4")
    parts.append(f"{L}/9-end.mp4")

with open(f"{L}/list.txt", "w") as fh:
    fh.writelines(f"file '{p}'\n" for p in parts)
run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", f"{L}/list.txt",
     "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-map", "0:v", "-map", "1:a", "-shortest",
     "-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", OUT])
print(OUT)
