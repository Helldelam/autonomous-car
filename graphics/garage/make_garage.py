"""Builds the garage images from the drawings in graphics/garage/source (development aid, like
graphics/technology/make_icons.py).

source/garage.png is the garage, 256 x 320 pixels (4 x 4 tiles at 64 pixels per tile, drawn at scale 0.5);
source/door.png is its door, 200 x 129 pixels, standing on the lower edge of the garage image, 27 pixels
from its left edge (DOOR_LEFT); source/remnants.png is the ruin, 600 x 352 pixels, the garage at x 62 to 316
and y 2 to 322 and its shadow on the right (prototypes/garage.lua centres it). All are drawn by hand.

Run: python -X utf8 graphics/garage/make_garage.py
Writes garage.png (the sprite), door.png and interior.png (the script slides door.png up over interior.png,
scripts/garage_door.lua), icon.png, garage-shadow.png and remnants/garage-remnants.png.
"""
import os
import random
import shutil
from PIL import Image, ImageDraw

MOD = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHEST = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\base\graphics\entity\steel-chest\steel-chest.png"
OUT = os.path.join(MOD, "graphics", "garage")
WIDTH, HEIGHT = 256, 320
DOOR_LEFT = 27


def build_interior(width, height):
    """What shows when the door is up: a dark hall, a little lighter towards the floor."""
    interior = Image.new("RGBA", (width, height), (0, 0, 0, 255))
    lines = ImageDraw.Draw(interior)
    for y in range(height):
        level = int(12 + 30 * (y / height) ** 2)
        lines.line([(0, y), (width, y)], fill=(level, level - 1, level + 1, 255))
    return interior


def add_grain(image):
    """A little noise, like the textures of the game, so the large flat parts are not too clean."""
    random.seed(7)
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            r, g, b, a = pixels[x, y]
            if a:
                d = random.randint(-5, 5)
                pixels[x, y] = (max(0, min(255, r + d)), max(0, min(255, g + d)), max(0, min(255, b + d)), a)


def build_icon(sprite):
    """64 pixels and its mipmaps (32, 16, 8) side by side: 120 x 64, like the icons of the game: the front
    of the garage: the whole building, centred in a square."""
    box = sprite.getbbox()
    size = max(box[2] - box[0], box[3] - box[1])
    square = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    square.alpha_composite(sprite.crop(box), ((size - (box[2] - box[0])) // 2, (size - (box[3] - box[1])) // 2))
    icon = Image.new("RGBA", (120, 64), (0, 0, 0, 0))
    x = 0
    for side in (64, 32, 16, 8):
        icon.alpha_composite(square.resize((side, side), Image.LANCZOS), (x, 0))
        x += side
    return icon


if __name__ == "__main__":
    sprite = Image.open(os.path.join(OUT, "source", "garage.png")).convert("RGBA")
    door = Image.open(os.path.join(OUT, "source", "door.png")).convert("RGBA")
    assert sprite.size == (WIDTH, HEIGHT)
    box = (DOOR_LEFT, HEIGHT - door.height, DOOR_LEFT + door.width, HEIGHT)
    sprite.save(os.path.join(OUT, "garage.png"))
    door.save(os.path.join(OUT, "door.png"))
    interior = build_interior(door.width, door.height)
    add_grain(interior)
    interior.save(os.path.join(OUT, "interior.png"))
    print("door box (image px, config.garage_door):", box)
    # The shadow of the steel chest, enlarged like the sprite (4 x 4 tiles instead of 1 x 1).
    shadow = Image.open(CHEST.replace("steel-chest.png", "steel-chest-shadow.png")).convert("RGBA")
    shadow.resize((shadow.width * 4, shadow.height * 4), Image.LANCZOS).save(os.path.join(OUT, "garage-shadow.png"))
    build_icon(sprite).save(os.path.join(OUT, "icon.png"))
    os.makedirs(os.path.join(OUT, "remnants"), exist_ok=True)
    shutil.copy(os.path.join(OUT, "source", "remnants.png"), os.path.join(OUT, "remnants", "garage-remnants.png"))
    print("garage.png", sprite.size)
