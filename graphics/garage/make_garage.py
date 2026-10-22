"""Builds the garage sprite and icon from the steel chest of the game (development aid, like
graphics/technology/make_icons.py).

The garage is 4 x 4 tiles; the game draws entities at 64 pixels per tile (scale 0.5), so the
sprite is 256 x 320. Stretching the 64 x 80 chest would be blurry: the chest is cut in bands
(rim, lid, ridge, front, foot) and columns (post, middle, post); the middle columns are tiled
and the bands stretched along the slats, so every detail keeps the pixel size of the game.
The door is the lid of the chest turned by 90 degrees, in a frame, with a hazard strip.

Run: python -X utf8 graphics/garage/make_garage.py
"""
import os
import random
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

MOD = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHEST = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\base\graphics\entity\steel-chest\steel-chest.png"
OUT = os.path.join(MOD, "graphics", "garage")
WIDTH, HEIGHT = 256, 320

chest = Image.open(CHEST).convert("RGBA")

# (first row, last row + 1) in the chest, tiled columns, height in the garage (None: stretched).
BANDS = [
    ((0, 8), (12, 48), 8),     # rim of the lid
    ((8, 34), (12, 48), None),  # slats of the lid
    ((34, 46), (8, 24), 12),   # ridge between the lid and the front
    ((46, 66), (8, 24), None),  # planks of the front
    ((66, 80), (8, 24), 14),   # foot
]
STRETCHED = HEIGHT - sum(band[2] for band in BANDS if band[2])


def build_band(rows, tile, height):
    """One band of the garage: the post on each side and the tiled middle."""
    top, bottom = rows
    band = Image.new("RGBA", (WIDTH, bottom - top), (0, 0, 0, 0))
    band.paste(chest.crop((0, top, 8, bottom)), (0, 0))
    band.paste(chest.crop((56, top, 64, bottom)), (WIDTH - 8, 0))
    piece = chest.crop((tile[0], top, tile[1], bottom))
    for x in range(8, WIDTH - 8, piece.width):
        band.paste(piece, (x, 0))
    # The last piece may spill over the right post: paste the post back.
    band.paste(chest.crop((56, top, 64, bottom)), (WIDTH - 8, 0))
    if height != bottom - top:
        band = band.resize((WIDTH, height), Image.LANCZOS)
    return band


def build_body():
    body = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    stretched = [band for band in BANDS if not band[2]]
    y = 0
    for rows, tile, height in BANDS:
        if not height:
            height = STRETCHED * (rows[1] - rows[0]) // sum(b[0][1] - b[0][0] for b in stretched)
        body.alpha_composite(build_band(rows, tile, height), (0, y))
        y += height
    return body


def build_door(width, height):
    """Roller shutter: the lid of the chest turned by 90 degrees, a little darker and greyer."""
    slats = chest.crop((12, 10, 48, 34)).rotate(90, expand=True)  # 24 x 36
    door = Image.new("RGBA", (width, height))
    for y in range(0, height, slats.height):
        for x in range(0, width, slats.width):
            door.paste(slats, (x, y))
    door = ImageEnhance.Color(door).enhance(0.45)
    door = ImageEnhance.Brightness(door).enhance(0.72)
    shade = Image.new("RGBA", door.size, (0, 0, 0, 0))
    lines = ImageDraw.Draw(shade)
    for y in range(height):  # the shutter is darker near its housing, at the top
        lines.line([(0, y), (width, y)], fill=(0, 0, 0, int(95 * max(0, 1 - y / (height * 0.55)))))
    door.alpha_composite(shade)
    return door


def draw_hazard(draw, box):
    """Yellow and black diagonal strip along the foot of the door."""
    left, top, right, bottom = box
    height = bottom - top
    draw.rectangle(box, fill=(224, 184, 52, 255))
    for x in range(left - height, right, 12):
        draw.polygon([(x, bottom), (x + 6, bottom), (x + 6 + height, top), (x + height, top)], fill=(30, 28, 26, 255))
    draw.rectangle((left, top, right, top), fill=(20, 18, 16, 255))
    draw.rectangle((left, bottom, right, bottom), fill=(20, 18, 16, 255))


def add_door(body):
    # Front of the garage: from the ridge (y = 8 + stretched lid + 8 ...) to the foot.
    front_top = sum(b[2] or 0 for b in BANDS[:2]) + (STRETCHED * 26 // 46) + 8
    front_bottom = HEIGHT - BANDS[4][2]
    frame = (36, front_top + 8, 220, front_bottom - 4)
    draw = ImageDraw.Draw(body)
    steel = chest.getpixel((30, 3))
    draw.rectangle(frame, fill=(22, 20, 22, 255))
    draw.rectangle((frame[0] + 1, frame[1] + 1, frame[2] - 1, frame[3] - 1), outline=steel, width=3)
    inner = (frame[0] + 5, frame[1] + 5, frame[2] - 5, frame[3] - 5)
    door = build_door(inner[2] - inner[0], inner[3] - inner[1] - 8)
    body.alpha_composite(door, (inner[0], inner[1]))
    draw = ImageDraw.Draw(body)
    draw_hazard(draw, (inner[0], inner[3] - 8, inner[2], inner[3]))
    # Lamp over the door.
    middle = (frame[0] + frame[2]) // 2
    draw.rectangle((middle - 9, frame[1] - 9, middle + 9, frame[1] - 3), fill=(40, 36, 30, 255))
    draw.rectangle((middle - 6, frame[1] - 8, middle + 6, frame[1] - 4), fill=(255, 205, 70, 255))
    draw.rectangle((middle - 3, frame[1] - 8, middle + 3, frame[1] - 7), fill=(255, 245, 190, 255))
    return inner


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
    """64 pixels and its mipmaps (32, 16, 8) side by side: 120 x 64, like the icons of the game."""
    # Only the front, seen straight on, with other proportions than the sprite so that the door
    # stays readable when small: thicker walls and frame, a taller hazard strip, a lighter door, a bigger lamp, more contrast.
    square = sprite.crop((28, HEIGHT - 200, 228, HEIGHT))
    # The slats of the lid, darker than the lid: the dark front of the chest would vanish against the inventory.
    plank = ImageEnhance.Brightness(chest.crop((12, 10, 48, 34))).enhance(0.68)
    for y in range(62, 200, plank.height):
        for x in range(0, 200, plank.width):
            square.paste(plank, (x, y))
    frame = (24, 90, 176, 196)  # down to the foot: no strip of wall under the door
    draw = ImageDraw.Draw(square)
    steel = chest.getpixel((30, 3))
    draw.rectangle(frame, fill=(22, 20, 22, 255))
    draw.rectangle((frame[0] + 1, frame[1] + 1, frame[2] - 1, frame[3] - 1), outline=steel, width=4)
    inner = (frame[0] + 7, frame[1] + 7, frame[2] - 7, frame[3] - 7)
    door = ImageEnhance.Brightness(build_door(inner[2] - inner[0], inner[3] - inner[1] - 16)).enhance(1.2)  # about as light as the lid
    square.alpha_composite(door, (inner[0], inner[1]))
    strip = Image.new("RGBA", (inner[2] - inner[0], 16))  # drawn apart: the stripes would spill over the frame
    draw_hazard(ImageDraw.Draw(strip), (0, 0, strip.width - 1, 15))
    square.alpha_composite(strip, (inner[0], inner[3] - 16))
    draw = ImageDraw.Draw(square)
    middle = (frame[0] + frame[2]) // 2
    draw.rectangle((middle - 16, frame[1] - 13, middle + 16, frame[1] - 2), fill=(40, 36, 30, 255))
    draw.rectangle((middle - 13, frame[1] - 12, middle + 13, frame[1] - 4), fill=(255, 205, 70, 255))
    draw.rectangle((middle - 7, frame[1] - 12, middle + 7, frame[1] - 9), fill=(255, 245, 190, 255))
    draw.rectangle((0, 0, 199, 199), outline=(22, 20, 22, 255), width=4) # dark edge that sets the icon off the background
    add_grain(square)
    red, green, blue, alpha = square.split()
    square = ImageEnhance.Contrast(Image.merge("RGB", (red, green, blue))).enhance(1.2).convert("RGBA")
    square.putalpha(alpha)
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


def build_remnants(sprite):
    """The ruin of the garage: the dark floor, what is left of the front wall (the foot, the planks, a piece of
    the door and its hazard strip) and of the side and back walls, torn at the top, sheets of the corrugated
    lid fallen on the floor, and the shadow of it all, like the remnants of the game."""
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
    door = sprite.crop((41, 190, 215, 297))
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
    sprite = build_body()
    inner = add_door(sprite)
    add_grain(sprite)
    sprite.save(os.path.join(OUT, "garage.png"))
    # The script lifts the door by squashing door.png over interior.png (scripts/garage_door.lua);
    # door.png is cut from the final sprite, so at full size it hides the interior exactly.
    sprite.crop(inner).save(os.path.join(OUT, "door.png"))
    interior = build_interior(inner[2] - inner[0], inner[3] - inner[1])
    add_grain(interior)
    interior.save(os.path.join(OUT, "interior.png"))
    print("door box (image px, config.garage_door):", inner)
    # The shadow of the steel chest, enlarged like the sprite (4 x 4 tiles instead of 1 x 1).
    shadow = Image.open(CHEST.replace("steel-chest.png", "steel-chest-shadow.png")).convert("RGBA")
    shadow.resize((shadow.width * 4, shadow.height * 4), Image.LANCZOS).save(os.path.join(OUT, "garage-shadow.png"))
    build_icon(sprite).save(os.path.join(OUT, "icon.png"))
    os.makedirs(os.path.join(OUT, "remnants"), exist_ok=True)
    build_remnants(sprite).save(os.path.join(OUT, "remnants", "garage-remnants.png"))
    print("garage.png", sprite.size)
