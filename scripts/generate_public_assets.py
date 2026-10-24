from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 64
SCALE = 8
INK = (0, 0, 0, 255)


def canvas() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    image = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
    return image, ImageDraw.Draw(image)


def spoke(draw: ImageDraw.ImageDraw, angle: float, inner: float, outer: float, width: float) -> None:
    centre = SIZE * SCALE / 2
    radians = math.radians(angle)
    delta_x, delta_y = math.cos(radians), math.sin(radians)
    start = (centre + delta_x * inner * SCALE, centre + delta_y * inner * SCALE)
    end = (centre + delta_x * outer * SCALE, centre + delta_y * outer * SCALE)
    draw.line([start, end], fill=INK, width=int(width * SCALE), joint="curve")
    for point in (start, end):
        radius = width * SCALE / 2
        draw.ellipse([point[0] - radius, point[1] - radius,
                      point[0] + radius, point[1] + radius], fill=INK)


def claude_mark() -> Image.Image:
    image, draw = canvas()
    for index in range(8):
        spoke(draw, index * 45 + 22.5, inner=3.5, outer=25, width=5.5)
    return image


def codex_mark() -> Image.Image:
    image, draw = canvas()
    centre = SIZE * SCALE / 2
    radius, width = 21 * SCALE, 5.5 * SCALE
    points = [(centre + radius * math.cos(math.radians(angle)),
               centre + radius * math.sin(math.radians(angle)))
              for angle in range(-90, 270, 60)]
    draw.line(points + [points[0]], fill=INK, width=int(width), joint="curve")
    for point in points:
        radius_cap = width / 2
        draw.ellipse([point[0] - radius_cap, point[1] - radius_cap,
                      point[0] + radius_cap, point[1] + radius_cap], fill=INK)
    return image


def grok_mark() -> Image.Image:
    image, draw = canvas()
    spoke(draw, 45, inner=-22, outer=22, width=6.0)
    spoke(draw, -45, inner=-22, outer=22, width=6.0)
    return image


def unknown_mark() -> Image.Image:
    image, draw = canvas()
    centre = SIZE * SCALE / 2
    radius = 6 * SCALE
    draw.ellipse([centre - radius, centre - radius, centre + radius, centre + radius], fill=INK)
    return image


def terminal_image(color: tuple[int, int, int], hybrid: bool) -> Image.Image:
    image = Image.new("RGBA", (192, 192), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((12, 12, 180, 180), radius=36, fill=color)
    draw.line((46, 57, 76, 86, 46, 115), fill="white", width=12)
    draw.line((94, 116, 145, 116), fill="white", width=12)
    if hybrid:
        draw.ellipse((128, 42, 154, 68), fill=(246, 194, 78))
    return image


def robot_image() -> Image.Image:
    image = Image.new("RGBA", (480, 480), (17, 33, 44, 255))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((72, 82, 408, 398), radius=82, fill=(56, 161, 171), outline=(221, 243, 245), width=12)
    draw.rounded_rectangle((119, 154, 361, 275), radius=24, fill=(17, 33, 44))
    draw.ellipse((155, 186, 190, 221), fill=(221, 243, 245))
    draw.ellipse((289, 186, 324, 221), fill=(221, 243, 245))
    draw.line((176, 326, 304, 326), fill=(221, 243, 245), width=12)
    return image


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Use a new output directory")
    images: dict[str, Image.Image] = {}
    marks = {"AgentClaude": claude_mark, "AgentCodex": codex_mark,
             "AgentGrok": grok_mark, "AgentUnknown": unknown_mark}
    for name, draw in marks.items():
        original = draw()
        for scale, size in ((1, 32), (2, 64), (3, 96)):
            images[f"{name}.imageset/{name}-{scale}x.png"] = original.resize((size, size), Image.Resampling.LANCZOS)
    for name, color in (("AppClaude", (193, 105, 64)), ("AppCodex", (69, 101, 183)), ("AppHybrid", (52, 139, 145))):
        images[f"{name}.imageset/{name}.png"] = terminal_image(color, name == "AppHybrid")
    robot = robot_image()
    for scale, size in ((1, 40), (2, 80), (3, 120)):
        images[f"HarnessAvatar.imageset/harness-{scale}x.png"] = robot.resize((size, size), Image.Resampling.LANCZOS)
    if len({name.casefold() for name in images}) != len(images):
        raise ValueError("Duplicate output")
    args.output.mkdir()
    for relative, image in images.items():
        destination = args.output / relative
        destination.parent.mkdir(exist_ok=True)
        with destination.open("xb") as stream:
            image.save(stream, format="PNG")
    print(f"Generated {len(images)} PNG files; asset catalog metadata is not changed")


if __name__ == "__main__":
    main()
