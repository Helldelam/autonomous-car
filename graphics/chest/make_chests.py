"""Builds the opening animation of the chests of the mod (development aid, like
graphics/garage/make_garage.py).

closed.png is the chest drawn from the logistic chest of the game (yellow, steel blue metal, hatch on
the front), finished by hand. The chests of the game open with 7 frames (opened_duration 7 ticks);
here the hatch of the front panel swings open on its hinges (on the left): it is squashed in
width towards its left edge, and the dark inside of the chest shows on its right.

One chest per colour of the logistic network: yellow (supply chest), blue (delivery chest, like the
requester chest) and purple (return chest, like the active provider chest); the yellow of closed.png is
turned to the hue of the colour, the steel blue metal stays.

Run: python -X utf8 graphics/chest/make_chests.py
Writes, for each colour, <colour>-sheet.png (7 frames of 66 x 74: what the game plays when a robot or a
player opens the chest), <colour>-icon.png (64 pixels and mipmaps: 120 x 64) and <colour>-door.png (the
hatch alone), and interior.png (the inside): a car opening a chest does not make the game play the
frames, so scripts/chest_door.lua draws the hatch (door.png squashed) over the interior.
"""
import colorsys
import os
import random
from PIL import Image, ImageDraw

OUT = os.path.dirname(os.path.abspath(__file__))
FRAMES = 7
HATCH = (13, 36, 53, 58)  # the door inside its frame (left, top, right, bottom, inclusive)
INSIDE_TOP, INSIDE_BOTTOM = (20, 24, 32), (44, 50, 60)  # the dark inside of the chest, top to bottom
COLORS = {  # name: (hue, value factor); None keeps the yellow
    "yellow": None,
    "blue": (0.61, 0.9),
    "purple": (0.78, 0.95),
}
LAST_HEIGHT = 0.12  # share of the width of the door still seen in the last frame


def draw_inside(image):
    left, top, right, bottom = HATCH
    draw = ImageDraw.Draw(image)
    for y in range(top, bottom + 1):
        t = (y - top) / (bottom - top)
        draw.line([(left, y), (right, y)], fill=tuple(round(INSIDE_TOP[i] * (1 - t) + INSIDE_BOTTOM[i] * t) for i in range(3)) + (255,))


def recolor(image, hue, value):
    """Turns the yellow of the chest (the lid and the hatch) to another hue; the metal is not yellow."""
    image = image.copy()
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if a and 0.08 < h < 0.2 and s > 0.35:
                r, g, b = colorsys.hsv_to_rgb(hue, min(1, s * 1.05), min(1, v * value))
                pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)
    return image


REMNANTS = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\base\graphics\entity\logistic-chest\remnants"
STEEL_HUE = 0.585
HUE_RANGES = {"yellow": (0.08, 0.2), "blue": (0.5, 0.68), "purple": (0.7, 0.88)}  # of the colour in the remnants of the game


def build_remnants(name, vanilla):
    """The remnants of the chest of the game of the same colour: its colour kept (turned to the hue
    of the chest), its metal in the steel blue of the sprites. The dark shadow is left alone."""
    image = Image.open(os.path.join(REMNANTS, vanilla + "-remnants.png")).convert("RGBA")
    pixels = image.load()
    low, high = HUE_RANGES[name]
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if not a or v < 0.15:
                continue
            if s > (0.4 if name == "yellow" else 0.28) and low < h < high:
                if COLORS[name]:
                    h = COLORS[name][0]
            else:
                h, s, v = STEEL_HUE, min(0.4, s * 0.8 + 0.12), min(1, v * 1.5 + 0.1)
            r, g, b = colorsys.hsv_to_rgb(h, s, v)
            pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)
    flatten_lid(image)
    return image


REMNANTS_IRIS = (21, 9, 52, 30)  # the round opening of the lid in the remnants of the game (left, top, right, bottom)


def flatten_lid(image):
    """The lid of the chest has no opening: the round hole of the remnants becomes a flat sheet of the
    colour of the lid, torn: a crack and a bent corner."""
    pixels = image.load()
    random.seed(3)
    left, top, right, bottom = REMNANTS_IRIS

    def average(y, x):  # the plate over a few columns, so that the fill has no streaks
        columns = [pixels[column, y] for column in range(x - 3, x + 4)]
        return [sum(pixel[i] for pixel in columns) / len(columns) for i in range(3)]

    for x in range(left, right + 1):
        above, below = average(top - 1, x), average(bottom + 1, x)
        for y in range(top, bottom + 1):
            t = (y - top) / (bottom - top)
            noise = random.randint(-6, 6)
            pixels[x, y] = tuple(max(0, min(255, round(above[i] * (1 - t) + below[i] * t) + noise)) for i in range(3)) + (255,)
    draw = ImageDraw.Draw(image)
    dark = tuple(round(c * 0.35) for c in pixels[(left + right) // 2, (top + bottom) // 2][:3]) + (255,)
    light = tuple(min(255, round(c * 1.25) + 10) for c in pixels[(left + right) // 2, (top + bottom) // 2][:3]) + (255,)
    draw.line([(26, 11), (30, 17), (29, 20), (35, 26)], fill=dark)  # a crack
    draw.line([(27, 11), (31, 17), (30, 20), (36, 26)], fill=light)  # its lit edge
    draw.polygon([(44, 10), (51, 10), (51, 17)], fill=light)  # a bent corner
    draw.line([(44, 10), (51, 17)], fill=dark)


def build_icon(chest):
    """The closed chest, 64 pixels and its mipmaps (32, 16, 8): 120 x 64."""
    box = chest.getbbox()
    size = max(box[2] - box[0], box[3] - box[1])
    square = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    square.alpha_composite(chest.crop(box), ((size - (box[2] - box[0])) // 2, (size - (box[3] - box[1])) // 2))
    icon = Image.new("RGBA", (120, 64), (0, 0, 0, 0))
    x = 0
    for side in (64, 32, 16, 8):
        icon.alpha_composite(square.resize((side, side), Image.LANCZOS), (x, 0))
        x += side
    return icon


def build_frame(closed, index):
    frame = closed.copy()
    if index == 0:
        return frame
    left, top, right, bottom = HATCH
    door = closed.crop((left, top, right + 1, bottom + 1))
    share = 1 - (1 - LAST_HEIGHT) * index / (FRAMES - 1)
    width = max(2, round(door.width * share))
    draw_inside(frame)
    frame.alpha_composite(door.resize((width, door.height), Image.BILINEAR), (left, top))
    return frame


if __name__ == "__main__":
    yellow = Image.open(os.path.join(OUT, "closed.png")).convert("RGBA")
    for name, color in COLORS.items():
        closed = recolor(yellow, *color) if color else yellow
        sheet = Image.new("RGBA", (closed.width * FRAMES, closed.height), (0, 0, 0, 0))
        for index in range(FRAMES):
            sheet.alpha_composite(build_frame(closed, index), (index * closed.width, 0))
        sheet.save(os.path.join(OUT, name + "-sheet.png"))
        build_icon(closed).save(os.path.join(OUT, name + "-icon.png"))
        # the hatch alone: scripts/chest_door.lua draws it over the chest when a car uses it
        closed.crop((HATCH[0], HATCH[1], HATCH[2] + 1, HATCH[3] + 1)).save(os.path.join(OUT, name + "-door.png"))
        print(name, sheet.size)
    os.makedirs(os.path.join(OUT, "remnants"), exist_ok=True)
    for name, vanilla in (("yellow", "storage-chest"), ("blue", "requester-chest"), ("purple", "active-provider-chest")):
        build_remnants(name, vanilla).save(os.path.join(OUT, "remnants", name + "-remnants.png"))
    inside = Image.new("RGBA", closed.size, (0, 0, 0, 0))
    draw_inside(inside)
    inside.crop((HATCH[0], HATCH[1], HATCH[2] + 1, HATCH[3] + 1)).save(os.path.join(OUT, "interior.png"))
