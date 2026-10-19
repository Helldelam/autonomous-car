import os
from PIL import Image, ImageFilter

MOD = r"<mod folder>"
CONST = r"C:\Program Files (x86)\Steam\steamapps\common\Factorio\data\core\graphics\icons\technology\constants"
out_dir = os.path.join(MOD, "graphics", "technology")
os.makedirs(out_dir, exist_ok=True)


def base(item):
    im = Image.open(os.path.join(MOD, "graphics", item, "icon.png")).convert("RGBA").crop((0, 0, 64, 64))
    # Upscale in two steps with a light sharpening, so the edges stay clean.
    im = im.resize((128, 128), Image.LANCZOS).filter(ImageFilter.UnsharpMask(radius=1.0, percent=60, threshold=2))
    im = im.resize((256, 256), Image.LANCZOS).filter(ImageFilter.UnsharpMask(radius=1.5, percent=50, threshold=2))
    return im


def mark(name):
    m = Image.open(os.path.join(CONST, "constant-%s.png" % name)).convert("RGBA").crop((0, 0, 128, 128))
    return m.resize((96, 96), Image.LANCZOS)


# name: (item, mark)
icons = {
    "main": ("car", None),
    "repair": ("garage", None),
    "cargo": ("car", "capacity"),
    "garage": ("garage", "capacity"),
    "chargers": ("charger", "count"),
    "charge_speed": ("charger", "speed"),
    "build_speed": ("car", "speed"),
}
for name, (item, m) in icons.items():
    im = base(item)
    if m:
        # bottom right corner, like the researches of the base game
        mk = mark(m)
        im.alpha_composite(mk, (256 - 96 - 4, 256 - 96 - 4))
    im.save(os.path.join(out_dir, name + ".png"))
    print(name, im.size)
