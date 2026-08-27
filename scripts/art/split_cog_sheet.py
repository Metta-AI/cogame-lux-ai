#!/usr/bin/env python3
"""Key, split and pad the nano-banana cog sheet into the four board sprites.

Input:  scripts/art/source/cogs_sheet.png — one `gemini-2.5-flash-image`
        ("nano-banana") render of four Softmax cogs on a flat green backdrop,
        laid out as a 2 x 2 grid:

            RED WORKER      BLUE WORKER
            RED CART        BLUE CART

Output: data/cogs/{red,blue}_{worker,cart}.png — 128 x 128 RGBA, transparent
        background, the character centred and padded to a square so every
        sprite shares one anchor when `src/lux/rig_art.nim` bakes it down to
        the 10/14/20 px board chips.

Gemini returns no alpha and the "pure green" backdrop comes back as *some*
green with a tinted anti-aliased edge, so the key is a flood fill from the
image border against the MEDIAN border colour (corners sometimes carry a
smudge). Filling from the border rather than thresholding on hue is what lets
green pixels inside a character survive.

Reproduce with:

    python3 scripts/art/split_cog_sheet.py

Requires Pillow only. The derived PNGs are committed — CI never regenerates
art.
"""

from __future__ import annotations

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SHEET = os.path.join(HERE, "source", "cogs_sheet.png")
OUT_DIR = os.path.join(ROOT, "data", "cogs")

# (row, column) -> output file stem. The sheet is a 2 x 2 grid.
CELLS = {
    (0, 0): "red_worker",
    (0, 1): "blue_worker",
    (1, 0): "red_cart",
    (1, 1): "blue_cart",
}

SIZE = 128           # output edge, px
PAD = 6              # transparent margin inside the square, px
TOLERANCE = 48       # per-channel distance from the backdrop colour


def median_border_colour(image: Image.Image) -> tuple[int, int, int]:
    width, height = image.size
    pixels = image.load()
    samples = []
    for x in range(width):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, height - 1][:3])
    for y in range(height):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[width - 1, y][:3])
    channels = []
    for index in range(3):
        values = sorted(sample[index] for sample in samples)
        channels.append(values[len(values) // 2])
    return (channels[0], channels[1], channels[2])


def key_backdrop(image: Image.Image) -> Image.Image:
    """Flood-fills the backdrop from every border pixel and clears its alpha."""
    image = image.convert("RGBA")
    width, height = image.size
    pixels = image.load()
    backdrop = median_border_colour(image)
    seen = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()

    def matches(x: int, y: int) -> bool:
        r, g, b, _ = pixels[x, y]
        return (
            abs(r - backdrop[0]) <= TOLERANCE
            and abs(g - backdrop[1]) <= TOLERANCE
            and abs(b - backdrop[2]) <= TOLERANCE
        )

    for x in range(width):
        for y in (0, height - 1):
            if not seen[y * width + x] and matches(x, y):
                seen[y * width + x] = 1
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if not seen[y * width + x] and matches(x, y):
                seen[y * width + x] = 1
                queue.append((x, y))

    while queue:
        x, y = queue.popleft()
        pixels[x, y] = (0, 0, 0, 0)
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < width and 0 <= ny < height:
                if not seen[ny * width + nx] and matches(nx, ny):
                    seen[ny * width + nx] = 1
                    queue.append((nx, ny))
    return image


def occupied_rows(image: Image.Image) -> list[bool]:
    width, height = image.size
    alpha = image.getchannel("A").load()
    rows = []
    for y in range(height):
        rows.append(any(alpha[x, y] > 8 for x in range(width)))
    return rows


def occupied_cols(image: Image.Image) -> list[bool]:
    width, height = image.size
    alpha = image.getchannel("A").load()
    cols = []
    for x in range(width):
        cols.append(any(alpha[x, y] > 8 for y in range(height)))
    return cols


def spans(flags: list[bool]) -> list[tuple[int, int]]:
    """Contiguous runs of True as (start, end_exclusive)."""
    out = []
    start = None
    for index, flag in enumerate(flags):
        if flag and start is None:
            start = index
        elif not flag and start is not None:
            out.append((start, index))
            start = None
    if start is not None:
        out.append((start, len(flags)))
    return out


def square(image: Image.Image) -> Image.Image:
    box = image.getbbox()
    if box is None:
        raise SystemExit("split_cog_sheet: an empty cell — check the key tolerance")
    cropped = image.crop(box)
    edge = max(cropped.size)
    inner = SIZE - 2 * PAD
    scale = inner / edge
    resized = cropped.resize(
        (max(1, round(cropped.width * scale)), max(1, round(cropped.height * scale))),
        Image.LANCZOS,
    )
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    canvas.paste(
        resized,
        ((SIZE - resized.width) // 2, (SIZE - resized.height) // 2),
        resized,
    )
    return canvas


def main() -> int:
    if not os.path.exists(SHEET):
        raise SystemExit("split_cog_sheet: missing " + SHEET)
    sheet = key_backdrop(Image.open(SHEET))
    rows = spans(occupied_rows(sheet))
    if len(rows) != 2:
        raise SystemExit(
            "split_cog_sheet: expected 2 sprite rows, found %d" % len(rows)
        )
    os.makedirs(OUT_DIR, exist_ok=True)
    for row_index, (top, bottom) in enumerate(rows):
        band = sheet.crop((0, top, sheet.width, bottom))
        cols = spans(occupied_cols(band))
        if len(cols) != 2:
            raise SystemExit(
                "split_cog_sheet: row %d has %d sprites, expected 2"
                % (row_index, len(cols))
            )
        for col_index, (left, right) in enumerate(cols):
            stem = CELLS[(row_index, col_index)]
            cell = square(band.crop((left, 0, right, band.height)))
            path = os.path.join(OUT_DIR, stem + ".png")
            cell.save(path)
            print("wrote", os.path.relpath(path, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
