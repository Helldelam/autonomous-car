"""Builds the garage images from the two drawings in graphics/garage/source (development aid, like
graphics/technology/make_icons.py).

source/garage.png is the garage, 256 x 320 pixels (4 x 4 tiles at 64 pixels per tile, drawn at scale 0.5);
source/door.png is its door, 200 x 129 pixels, standing on the lower edge of the garage image, 27 pixels
from its left edge (DOOR_LEFT). Both are drawn by hand.

Run: python -X utf8 graphics/garage/make_garage.py
Writes garage.png (the sprite), door.png and interior.png (the script lifts the door by squashing door.png
over interior.png, scripts/garage_door.lua), icon.png, garage-shadow.png and remnants/garage-remnants.png.
"""
import os
import random
from PIL import Image, ImageDraw, ImageFilter

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
    of the garage, seen straight on, with the door."""
    square = sprite.crop((DOOR_LEFT, HEIGHT - 200, DOOR_LEFT + 200, HEIGHT))
    icon = Image.new("RGBA", (120, 64), (0, 0, 0, 0))
    x = 0
    for side in (64, 32, 16, 8):
        icon.alpha_composite(square.resize((side, side), Image.LANCZOS), (x, 0))
        x += side
    return icon


REMNANTS_SIZE = (376, 300)  # the 256 x 200 ruin in the middle, its shadow on the right; drawn at scale 0.5 like the sprite
FLOOR_TOP, FRONT_BOTTOM, LEFT, RIGHT = 90, 250, 60, 316  # the footprint of the ruin in that image


def torn_piece(texture, box, top_range, rng, seed_bottom=False):
    """A band of `texture` (a box of the sprite) whose top edge is torn: each column keeps a random
    height (a random walk) between the two bounds of top_range."""
    left, top, right, bottom = box
    band = texture.crop(box)
    low, high = top_range  # height kept at the lowest and at the highest point of the tear
    piece = Image.new("RGBA", band.size, (0, 0, 0, 0))
    height = rng.uniform(low, high)
    for x in range(band.width):
        height = min(high, max(low, height + rng.uniform(-4, 4)))
        kept = int(min(band.height, height))
        piece.paste(band.crop((x, band.height - kept, x + 1, band.height)), (x, band.height - kept))
    return piece


def debris(texture, rng, size):
    """A torn polygon cut from `texture`, turned at random."""
    w, h = size
    x, y = rng.randint(0, texture.width - w), rng.randint(0, texture.height - h)
    cut = texture.crop((x, y, x + w, y + h))
    mask = Image.new("L", (w, h), 0)
    points = [(rng.uniform(0, 0.25) * w, rng.uniform(0, 0.25) * h), (w * rng.uniform(0.7, 1), rng.uniform(0, 0.3) * h),
              (w, h * rng.uniform(0.6, 1)), (w * rng.uniform(0.3, 0.7), h), (rng.uniform(0, 0.2) * w, h * rng.uniform(0.6, 0.95))]
    ImageDraw.Draw(mask).polygon(points, fill=255)
    cut.putalpha(mask)
    edge = ImageDraw.Draw(cut)
    edge.line(points + [points[0]], fill=(30, 28, 30, 255), width=1)  # the dark edge of the torn sheet
    return cut.rotate(rng.uniform(-40, 40), expand=True, resample=Image.BICUBIC)


def build_remnants(sprite, door):
    """The ruin of the garage: the dark floor, what is left of the front wall (the foot, the planks, a piece of
    the door and its hazard strip) and of the side and back walls, torn at the top, sheets of the lid
    fallen on the floor, and the shadow of it all, like the remnants of the game."""
    rng = random.Random(5)
    lid, front = sprite.crop((0, 0, WIDTH, 170)), sprite.crop((0, 176, WIDTH, HEIGHT))
    ruin = Image.new("RGBA", REMNANTS_SIZE, (0, 0, 0, 0))
    # The floor, a little uneven at the edges.
    floor = Image.new("RGBA", REMNANTS_SIZE, (0, 0, 0, 0))
    ImageDraw.Draw(floor).polygon([(LEFT + 4 + rng.randint(-3, 3), FLOOR_TOP + rng.randint(0, 8)) for _ in range(1)]
                                  + [(x, FLOOR_TOP + rng.randint(0, 8)) for x in range(LEFT + 10, RIGHT - 10, 24)]
                                  + [(RIGHT - 4, FLOOR_TOP + 6), (RIGHT, FRONT_BOTTOM), (LEFT, FRONT_BOTTOM)], fill=(255, 255, 255, 255))
    ground = Image.new("RGBA", REMNANTS_SIZE, (0, 0, 0, 255))
    shades = ImageDraw.Draw(ground)
    for y in range(REMNANTS_SIZE[1]):
        level = int(14 + 26 * min(1, max(0, (y - FLOOR_TOP) / (FRONT_BOTTOM - FLOOR_TOP))) ** 2)
        shades.line([(0, y), (REMNANTS_SIZE[0], y)], fill=(level, level - 1, level + 1, 255))
    ground.putalpha(floor.getchannel("A"))
    ruin.alpha_composite(ground)
    # The back wall, torn, with a gap; the side walls; the front wall with the door.
    back = torn_piece(lid, (0, 0, WIDTH, 60), (24, 50), rng)
    back.paste((0, 0, 0, 0), (96 + rng.randint(0, 20), 0, 140 + rng.randint(0, 30), 60))
    ruin.alpha_composite(back, (LEFT, FLOOR_TOP - 40))
    for x in (LEFT - 2, RIGHT - 24):
        ruin.alpha_composite(torn_piece(front, (0, 0, 26, 144), (36, 112), rng), (x, FRONT_BOTTOM - 144 + 2))
    wall = torn_piece(front, (0, 20, WIDTH, 144), (40, 100), rng)
    ruin.alpha_composite(wall, (LEFT, FRONT_BOTTOM - wall.height))
    # Sheets of the lid and scraps of the door on the floor.
    for _ in range(7):
        piece = debris(lid if rng.random() < 0.75 else door, rng, (rng.randint(30, 56), rng.randint(20, 40)))
        ruin.alpha_composite(piece, (rng.randint(LEFT + 20, RIGHT - 60), rng.randint(FLOOR_TOP + 10, FRONT_BOTTOM - 90)))
    # Soot and dust, then the shadow on the right.
    add_grain(ruin)
    shadow = Image.new("RGBA", REMNANTS_SIZE, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 120), mask=ruin.getchannel("A").point(lambda a: 255 if a > 40 else 0).transform(
        REMNANTS_SIZE, Image.AFFINE, (1, 0, -34, 0, 1, -6)))  # shifted by 34 right, 6 down
    result = shadow.filter(ImageFilter.GaussianBlur(2))
    result.alpha_composite(ruin)
    return result


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
    build_remnants(sprite, door).save(os.path.join(OUT, "remnants", "garage-remnants.png"))
    print("garage.png", sprite.size)
