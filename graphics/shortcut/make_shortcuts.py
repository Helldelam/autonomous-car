"""Builds the icons of the two shortcuts (development aid, like graphics/car/make_car.py).

- selector: the ghost of the editor of the game in selection corners, the car (graphics/car/icon.png) as a
  badge: what the tool does (select ghosts) and who does it. selector-x56.png and selector-x24.png are the
  icon and small icon of the shortcut, selector-icon.png (64) the icon of the item in the cursor.
- missing: a white warning triangle (a little larger than the one of the game: 40 pixels of 56) with the car
  as a badge. missing-x56.png and missing-x24.png.
Drawn at 4 times the size and reduced.

Run: python -X utf8 graphics/shortcut/make_shortcuts.py
"""
import os
from PIL import Image, ImageDraw

OUT = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(os.path.dirname(OUT))
GHOST = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\core\graphics\icons\mip\ghost-entity.png"
K = 4  # drawing scale
SIZE = 56 * K
WHITE = (255, 255, 255, 255)


def fit(image, size):
    ratio = size / max(image.size)
    return image.resize((round(image.width * ratio), round(image.height * ratio)), Image.LANCZOS)


def corner_mark(draw):
    for x, y, sx, sy in ((5, 5, 1, 1), (50, 5, -1, 1), (5, 50, 1, -1), (50, 50, -1, -1)):
        draw.line([(x * K, y * K), ((x + 8 * sx) * K, y * K)], fill=WHITE, width=2 * K)
        draw.line([(x * K, y * K), (x * K, (y + 8 * sy) * K)], fill=WHITE, width=2 * K)


def badge(image, car, size=28):
    car = fit(car, size * K)
    image.alpha_composite(car, (SIZE - car.width, SIZE - car.height))


def build_selector(car):
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    corner_mark(ImageDraw.Draw(image))
    ghost = fit(Image.open(GHOST).convert("RGBA").crop((0, 0, 64, 64)), 30 * K)
    image.alpha_composite(ghost, ((SIZE - ghost.width) // 2, (SIZE - ghost.height) // 2 - 2 * K))
    badge(image, car)
    return image


def build_missing(car):
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    side, top, bottom, middle = 40 * K, 5 * K, 41 * K, 25 * K  # triangle, up and to the left of the badge
    points = [(middle, top), (middle + side // 2 - 2 * K, bottom), (middle - side // 2 + 2 * K, bottom)]
    draw.line(points + [points[0], points[1]], fill=WHITE, width=4 * K, joint="curve")
    for point in points:  # rounded corners
        draw.ellipse([point[0] - 2 * K, point[1] - 2 * K, point[0] + 2 * K, point[1] + 2 * K], fill=WHITE)
    draw.rounded_rectangle([middle - 2 * K, 17 * K, middle + 2 * K, 30 * K], radius=K, fill=WHITE)
    draw.ellipse([middle - 2 * K, 33 * K, middle + 2 * K, 37 * K], fill=WHITE)
    badge(image, car, 26)
    return image


def save(image, name, size):
    image.resize((size, size), Image.LANCZOS).save(os.path.join(OUT, name))


if __name__ == "__main__":
    car = Image.open(os.path.join(MOD, "graphics", "car", "icon.png")).convert("RGBA").crop((0, 0, 64, 64))
    selector, missing = build_selector(car), build_missing(car)
    save(selector, "selector-x56.png", 56)
    save(selector, "selector-x24.png", 24)
    save(selector, "selector-icon.png", 64)
    save(missing, "missing-x56.png", 56)
    save(missing, "missing-x24.png", 24)
