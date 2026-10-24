"""Builds the opening animation of the chests of the mod (development aid, like
graphics/garage/make_garage.py).

closed.png is the chest drawn from the logistic chest of the game (yellow, steel blue metal, hatch on
the front, round opening of the lid), finished by hand, as is its ruin, source/yellow-remnants.png. The chests of the game open with 7 frames (opened_duration 7 ticks);
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


def build_remnants(name):
    """The remnants of the chest: the yellow ones are drawn by the owner (source/yellow-remnants.png, the
    ruin of the closed chest, 116 x 82), the others turn their yellow to the hue of the chest."""
    image = Image.open(os.path.join(OUT, "source", "yellow-remnants.png")).convert("RGBA")
    return recolor(image, *COLORS[name]) if COLORS[name] else image


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
    for name in COLORS:
        build_remnants(name).save(os.path.join(OUT, "remnants", name + "-remnants.png"))
    inside = Image.new("RGBA", closed.size, (0, 0, 0, 0))
    draw_inside(inside)
    inside.crop((HATCH[0], HATCH[1], HATCH[2] + 1, HATCH[3] + 1)).save(os.path.join(OUT, "interior.png"))
