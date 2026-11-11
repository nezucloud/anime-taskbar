"""Shared frame geometry and additive-light helpers for the taskbar sprites."""
import math

import numpy as np
from PIL import Image

CELL_W, HEIGHT = 96, 48          # one character cell; HEIGHT matches a 100%-scale Windows 11 taskbar
WHITE = (255, 255, 255)


def add_blob(light: np.ndarray, centre, sigma: float, colour, strength: float):
    """Add a soft Gaussian spot of light (premultiplied RGB + alpha) to `light` in place."""
    cx, cy = centre
    reach = int(math.ceil(sigma * 3))
    x0, x1 = max(0, int(cx) - reach), min(light.shape[1], int(cx) + reach + 2)
    y0, y1 = max(0, int(cy) - reach), min(light.shape[0], int(cy) + reach + 2)
    if x0 >= x1 or y0 >= y1:
        return
    ys, xs = np.mgrid[y0:y1, x0:x1].astype(np.float32)
    falloff = strength * np.exp(-((xs - cx) ** 2 + (ys - cy) ** 2) / (2 * sigma * sigma))
    light[y0:y1, x0:x1, :3] += falloff[..., None] * np.asarray(colour, np.float32) / 255
    light[y0:y1, x0:x1, 3] += falloff


def mix(a, b, t: float):
    return tuple(x * (1 - t) + y * t for x, y in zip(a, b))


def composite(base: np.ndarray, light: np.ndarray) -> Image.Image:
    """Add light on top of premultiplied art; return straight-alpha RGBA for PNG."""
    glow_alpha = np.clip(light[..., 3], 0, 1)
    alpha = np.clip(base[..., 3] + glow_alpha * (1 - base[..., 3]), 0, 1)
    rgb = np.minimum(base[..., :3] + light[..., :3], alpha[..., None])
    straight = np.where(alpha[..., None] > 0, rgb / np.maximum(alpha[..., None], 1e-6), 0)
    rgba = np.dstack([straight, alpha]) * 255
    return Image.fromarray(rgba.clip(0, 255).astype(np.uint8), "RGBA")
