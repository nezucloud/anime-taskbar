"""Cut character heads out of real artwork, ready for make_moods.py to animate.

characters.json entries: {"name", "image", "cell": [l, t, r, b], "box": [l, t, r, b], "eyes": [[x, y], [x, y]], "glow": [r, g, b]}
All coordinates are pixels in the source image. `cell` must hold the whole character on a dark, neutral
background (sticker-style art with a light outline works best); the character is cut out there, then
cropped to the head `box`, and the cut-off body fades out at the bottom.
"""
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from glow import CELL_W, HEIGHT

BACKGROUND_MAX_LUMINANCE = 110       # background = dark ...
BACKGROUND_MAX_SATURATION = 0.25     # ... and nearly grey
BOTTOM_FADE = 0.18                   # fraction of the crop height that fades out where the body is cut
REMOVED, KEPT = 64, 200


@dataclass
class Head:
    name: str
    pixels: np.ndarray       # premultiplied RGBA float cell, HEIGHT x CELL_W
    eyes: list               # [(x, y), (x, y)] in cell coordinates, left eye first
    glow: tuple
    width: float             # drawn head width in cell pixels


def background_like(rgb: np.ndarray) -> np.ndarray:
    high, low = rgb.max(axis=2), rgb.min(axis=2)
    saturation = (high - low) / np.maximum(high, 1)
    luminance = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    return (luminance < BACKGROUND_MAX_LUMINANCE) & (saturation < BACKGROUND_MAX_SATURATION)


def flood(mask: np.ndarray, seeds: list, fill: int) -> np.ndarray:
    """Flood-fill the True region of `mask` from each seed; return where the fill reached."""
    image = Image.fromarray(np.where(mask, 255, 0).astype(np.uint8)).copy()   # fromarray views are read-only
    for seed in seeds:
        if image.getpixel(seed) == 255:
            ImageDraw.floodfill(image, seed, fill)
    return np.asarray(image) == fill


def cutout(rgb: np.ndarray, inside: tuple) -> np.ndarray:
    """Alpha mask of the character containing `inside`, cut from the background around it."""
    height, width = rgb.shape[:2]
    edge_seeds = [(x, 0) for x in range(width)] + [(x, height - 1) for x in range(width)] + \
                 [(0, y) for y in range(height)] + [(width - 1, y) for y in range(height)]
    background = flood(background_like(rgb), edge_seeds, REMOVED)
    character = flood(~background, [inside], KEPT)        # drops loose bits like sweat drops and labels
    return character.astype(np.float32)


def fade_bottom(alpha: np.ndarray) -> np.ndarray:
    fade_rows = int(alpha.shape[0] * BOTTOM_FADE)
    faded = alpha.copy()
    faded[-fade_rows:] *= np.linspace(1, 0, fade_rows, dtype=np.float32)[:, None]
    return faded


def load_head(entry: dict, source_dir: Path, head_height: int) -> Head:
    cell_left, cell_top, cell_right, cell_bottom = entry["cell"]
    source = Image.open(source_dir / entry["image"]).convert("RGB")
    cell_rgb = np.asarray(source.crop((cell_left, cell_top, cell_right, cell_bottom)), np.float32)
    first_eye = tuple(int(v) for v in np.subtract(entry["eyes"][0], (cell_left, cell_top)))
    cell_alpha = cutout(cell_rgb, first_eye)

    left, top, right, bottom = entry["box"]
    rows = slice(top - cell_top, bottom - cell_top)
    cols = slice(left - cell_left, right - cell_left)
    rgb, alpha = cell_rgb[rows, cols], fade_bottom(cell_alpha[rows, cols])
    premultiplied = np.dstack([rgb * alpha[..., None], alpha * 255]).astype(np.uint8)

    scale = head_height / (bottom - top)
    width = round((right - left) * scale)
    small = Image.fromarray(premultiplied, "RGBA").resize((width, head_height), Image.LANCZOS)
    pixels = np.zeros((HEIGHT, CELL_W, 4), np.float32)
    x0, y0 = (CELL_W - width) // 2, HEIGHT - head_height
    pixels[y0:, x0:x0 + width] = np.asarray(small, np.float32) / 255
    eyes = sorted((x0 + (x - left) * scale, y0 + (y - top) * scale) for x, y in entry["eyes"])
    return Head(entry["name"], pixels, eyes, tuple(entry["glow"]), width)
