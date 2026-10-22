"""Builds the charger images from the accumulator of the game (development aid, like
graphics/garage/make_garage.py).

- charger.png: the accumulator in steel blue, its blue and red wires turned into graphite cables
  (the yellow terminal loops stay, as the accent), without its four charging posts.
- post.png: a charging post, drawn by the script (scripts/charger_visual.lua) around the charger,
  as many as it has places (2, 4 or 8 with the research). Drawn by the owner from the beacon of the
  game (source/post.png), here lightened, with its red cable turned yellow.
- support-<corner>.png: the support under a post, one per corner (source/support.png, cut from the
  medium electric pole, made for the top left corner; the others are its mirrors), in the steel of the body.
- charger-shadow.png: the shadow of the accumulator without the shadows of its two right-hand posts
  (shadows always fall to the right), and post-shadow.png, the shadow of one post, drawn by the script.
- arc.png: 12 frames of electric arcs, drawn at the tip of a post while a car charges on it.
- icon.png: the charger with its four posts, 64 pixels and mipmaps.

Run: python -X utf8 graphics/charger/make_charger.py
"""
import colorsys
import math
import os
import random
from PIL import Image, ImageDraw, ImageFilter, ImageOps

MOD = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SOURCE = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\base\graphics\entity\accumulator\accumulator.png"
OUT = os.path.join(MOD, "graphics", "charger")
SHADOW_SOURCE = SOURCE.replace("accumulator.png", "accumulator-shadow.png")
STEEL_HUE = 0.585  # 210 degrees
YELLOW_HUE = 0.14  # the yellow cables of the charger

# The four posts of the accumulator, with the rods and wires that lead to them (x0, y0, x1, y1).
OLD_POSTS = [(0, 0, 30, 42), (100, 0, 130, 42), (0, 95, 8, 126), (122, 95, 130, 126)]

POST_BODY_SIZE = (22, 41)  # the post at the scale of the body (0.5), the one the owner wants: 40 pixels, for a body of 140
# Corners of the body in tiles from the charger, the first posts of config.charger_visual.posts: top left, top right, bottom left, bottom right.
CORNERS = [(-0.78, -0.98), (0.78, -0.98), (-0.78, 0.04), (0.78, 0.04)]
ARC_SIZE = 64
ARC_FRAMES = 12


def recolor(sprite):
    pixels = sprite.load()
    for y in range(sprite.height):
        for x in range(sprite.width):
            r, g, b, a = pixels[x, y]
            if not a:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            cable = (s > 0.55 and v > 0.3 and (0.5 < h < 0.75 or h < 0.04 or h > 0.95)) \
                or (s > 0.4 and v > 0.25 and (h < 0.1 or h > 0.93))
            if cable:  # blue and red wires: graphite
                s, v = 0.1, v * 0.5
                h = STEEL_HUE
            elif 0.4 < h < 0.8:  # lavender tops and teal bodies: steel blue
                h, s = STEEL_HUE, min(1, s * 0.8 + 0.05)
            elif (h < 0.12 or h > 0.9) and s < 0.55:  # rusty edges of the frame
                s *= 0.3
            r, g, b = colorsys.hsv_to_rgb(h, s, v)
            pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)


def build_shadows():
    """The vanilla shadow without the thin shadows of the two right-hand posts, and one of them apart."""
    shadow = Image.open(SHADOW_SOURCE).convert("RGBA")
    post = shadow.crop((144, 2, 234, 13))
    draw = ImageDraw.Draw(shadow)
    draw.rectangle((144, 0, 233, 13), fill=(0, 0, 0, 0))
    draw.rectangle((144, 96, 233, 105), fill=(0, 0, 0, 0))
    return shadow, post


def build_post():
    """The post of the owner: its red cable turned yellow, the rest lighter and a little bluer so
    that it stands out from the ground."""
    post = Image.open(os.path.join(OUT, "source", "post.png")).convert("RGBA")
    pixels = post.load()
    for y in range(post.height):
        for x in range(post.width):
            r, g, b, a = pixels[x, y]
            if not a:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if s > 0.45 and (h < 0.06 or h > 0.93):  # the red cable
                h, s, v = YELLOW_HUE, min(1, s * 1.1), min(1, v * 1.5)
            else:  # metal: lighter, with a hint of steel blue
                h, s, v = STEEL_HUE, max(s, 0.22), min(0.9, v * 1.1 + 0.05)
            r, g, b = colorsys.hsv_to_rgb(h, s, v)
            pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)
    return post


def build_supports():
    """The support in the steel of the body, for each corner: top left as drawn, the others mirrored."""
    support = Image.open(os.path.join(OUT, "source", "support.png")).convert("RGBA")
    pixels = support.load()
    for y in range(support.height):
        for x in range(support.width):
            r, g, b, a = pixels[x, y]
            if not a:
                continue
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            r, g, b = colorsys.hsv_to_rgb(STEEL_HUE, 0.3, min(1, v * 0.9 + 0.05))
            pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)
    return {
        "tl": support,
        "tr": ImageOps.mirror(support),
        "bl": ImageOps.flip(support),
        "br": ImageOps.flip(ImageOps.mirror(support)),
    }


def build_arcs():
    """Jagged bolts leaving the centre of each frame, cyan with a white core."""
    random.seed(11)
    scale = 4
    size = ARC_SIZE * scale
    sheet = Image.new("RGBA", (ARC_SIZE * 6, ARC_SIZE * (ARC_FRAMES // 6)), (0, 0, 0, 0))
    for frame in range(ARC_FRAMES):
        glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        core = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        for _ in range(random.randint(2, 3)):
            point = [size / 2, size / 2]
            angle = random.uniform(-math.pi, 0)  # upwards and sideways
            length = random.uniform(20, 30) * scale
            steps = 5
            for _ in range(steps):
                angle += random.uniform(-0.9, 0.9)
                new = [point[0] + math.cos(angle) * length / steps, point[1] + math.sin(angle) * length / steps]
                for layer, colour, width in ((glow, (60, 160, 255, 255), 9), (core, (225, 248, 255, 255), 4)):
                    ImageDraw.Draw(layer).line([tuple(point), tuple(new)], fill=colour, width=width * scale // 2)
                point = new
        glow = glow.filter(ImageFilter.GaussianBlur(scale * 1.5))
        glow.alpha_composite(core)
        frame_image = glow.resize((ARC_SIZE, ARC_SIZE), Image.LANCZOS)
        sheet.alpha_composite(frame_image, ((frame % 6) * ARC_SIZE, (frame // 6) * ARC_SIZE))
    return sheet


def build_icon(body, post):
    """The charger with its four posts, 64 pixels and its mipmaps (32, 16, 8): 120 x 64."""
    canvas = Image.new("RGBA", (200, 189), (0, 0, 0, 0))
    post = post.resize(POST_BODY_SIZE, Image.LANCZOS)
    canvas.alpha_composite(body, (35, 0))
    for x, y in CORNERS:  # in front of the body, so that they stay visible at 64 pixels
        canvas.alpha_composite(post, (round(35 + 65 + 64 * x - post.width / 2), round(94.5 + 22 + 64 * y - post.height)))
    box = canvas.getbbox()
    size = max(box[2] - box[0], box[3] - box[1])
    square = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    square.alpha_composite(canvas.crop(box), ((size - (box[2] - box[0])) // 2, (size - (box[3] - box[1])) // 2))
    icon = Image.new("RGBA", (120, 64), (0, 0, 0, 0))
    x = 0
    for side in (64, 32, 16, 8):
        icon.alpha_composite(square.resize((side, side), Image.LANCZOS), (x, 0))
        x += side
    return icon


if __name__ == "__main__":
    body = Image.open(SOURCE).convert("RGBA")
    for box in OLD_POSTS:
        ImageDraw.Draw(body).rectangle(box, fill=(0, 0, 0, 0))
    recolor(body)
    body.save(os.path.join(OUT, "charger.png"))
    shadow, post_shadow = build_shadows()
    shadow.save(os.path.join(OUT, "charger-shadow.png"))
    post_shadow.save(os.path.join(OUT, "post-shadow.png"))
    post = build_post()
    post.save(os.path.join(OUT, "post.png"))
    for corner, support in build_supports().items():
        support.save(os.path.join(OUT, "support-" + corner + ".png"))
    build_arcs().save(os.path.join(OUT, "arc.png"))
    build_icon(body, post).save(os.path.join(OUT, "icon.png"))
    print("charger.png", body.size, "post.png", post.size, "arc.png", ARC_SIZE, "x", ARC_FRAMES)
