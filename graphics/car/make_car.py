"""Builds the car icon and remnants (development aid, like graphics/charger/make_charger.py).

The car is the car of the game, painted at runtime with the colour of scripts/colors.lua (its mask layer
is tinted). Here that colour is TINT (the same as in colors.lua, without its alpha).
- icon.png: the car of the game recoloured: the blue of the old icon is turned to the colour of the car.
  Run once on the old icon (the pixels already turned are left as they are by a second run).
- remnants/car-remnants.png: the remnants of the car of the game (4 directions of 302 x 300 pixels), their
  mask layer, which the game tints at runtime, baked in the colour of the car; prototypes/car.lua draws
  them at scale 0.25, like the car (the car of the game is at 0.5).

Run: python -X utf8 graphics/car/make_car.py
"""
import colorsys
import os
from PIL import Image

OUT = os.path.dirname(os.path.abspath(__file__))
GAME = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\base\graphics\entity\car\remnants"
TINT = (0.28, 0.40, 0.58)  # scripts/colors.lua
OLD_HUE_RANGE = (0.5, 0.68)
HUE = colorsys.rgb_to_hsv(*TINT)[0]


def recolor_icon(icon):
    """The blue of the old tint (very saturated) toward the colour of the car: less saturated, a little darker."""
    icon = icon.copy()
    pixels = icon.load()
    for y in range(icon.height):
        for x in range(icon.width):
            r, g, b, a = pixels[x, y]
            h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if a and OLD_HUE_RANGE[0] < h < OLD_HUE_RANGE[1] and s > 0.6:
                r, g, b = colorsys.hsv_to_rgb(HUE, s * 0.55, v * 0.85)
                pixels[x, y] = (round(r * 255), round(g * 255), round(b * 255), a)
    return icon


def bake_remnants():
    base = Image.open(os.path.join(GAME, "car-remnants.png")).convert("RGBA")
    mask = Image.open(os.path.join(GAME, "mask", "car-remnants-mask.png")).convert("RGBA")
    width, height = 302, 300
    mask_width, mask_height = 196, 146
    result = base.copy()
    for direction in range(4):
        frame = mask.crop((0, direction * mask_height, mask_width, (direction + 1) * mask_height))
        pixels = frame.load()
        for y in range(frame.height):
            for x in range(frame.width):
                r, g, b, a = pixels[x, y]
                if a:
                    lum = (r + g + b) / 3 / 255
                    pixels[x, y] = tuple(round(255 * min(1, lum * t)) for t in TINT) + (a,)
        result.alpha_composite(frame, ((width - mask_width) // 2, direction * height + (height - mask_height) // 2))
    return result


if __name__ == "__main__":
    icon_path = os.path.join(OUT, "icon.png")
    recolor_icon(Image.open(icon_path).convert("RGBA")).save(icon_path)
    os.makedirs(os.path.join(OUT, "remnants"), exist_ok=True)
    bake_remnants().save(os.path.join(OUT, "remnants", "car-remnants.png"))
    print("icon and remnants written")
