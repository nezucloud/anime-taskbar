"""Render the taskbar heads in three moods that the player switches between by CPU/RAM load.

Usage: python make_moods.py <characters.json> <output stem>
Writes <stem>_calm.png, <stem>_busy.png, <stem>_exhausted.png (vertical sprite sheets) and <stem>.json.
Every mood starts and ends its loop in the same neutral-ish pose, so the player switches at frame 0.
"""
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from glow import CELL_W, HEIGHT, WHITE, add_blob, composite, mix
from make_from_images import Head, load_head

HEAD_HEIGHT = 42
FRAME_COUNT = 60
FRAME_MS = 40
PIVOT = (CELL_W / 2, HEIGHT - 2)          # heads tilt around the neck
SWEAT = (150, 215, 255)
SWEAT_OUTLINE = (40, 95, 170)
BLUSH = (255, 85, 110)
SUPERSAMPLE = 4


@dataclass(frozen=True)
class Mood:
    name: str
    bob_px: float            # vertical breathing amplitude
    bob_cycles: int          # breaths per loop
    tilt_deg: float          # steady droop to one side
    sway_deg: float          # tilt wobble around the droop
    sink_px: float           # how far the head slumps down
    fire_strength: float
    fire_length: float
    fire_cycles: int         # flame particle cycles per loop
    sputter: float           # 0 = steady fire, 1 = fire keeps cutting out
    sweat_drops: int         # per head
    steam_puffs: int         # per head
    blush: float


MOODS = [
    Mood("calm", bob_px=0.8, bob_cycles=1, tilt_deg=0, sway_deg=0, sink_px=0,
         fire_strength=0.62, fire_length=24, fire_cycles=2, sputter=0, sweat_drops=0, steam_puffs=0, blush=0),
    Mood("busy", bob_px=1.2, bob_cycles=3, tilt_deg=0, sway_deg=2.5, sink_px=0.5,
         fire_strength=0.75, fire_length=30, fire_cycles=3, sputter=0.15, sweat_drops=1, steam_puffs=0, blush=0.25),
    Mood("exhausted", bob_px=0.9, bob_cycles=5, tilt_deg=11, sway_deg=3, sink_px=3,
         fire_strength=0.45, fire_length=14, fire_cycles=2, sputter=0.7, sweat_drops=2, steam_puffs=3, blush=0.55),
]


# ---------- pose ----------

@dataclass
class Pose:
    angle: float     # radians, positive tilts the head toward the viewer's right
    dx: float
    dy: float

    def apply(self, point):
        x, y = point[0] - PIVOT[0], point[1] - PIVOT[1]
        c, s = math.cos(self.angle), math.sin(self.angle)
        return (PIVOT[0] + c * x - s * y + self.dx, PIVOT[1] + s * x + c * y + self.dy)


def pose_for(mood: Mood, index: int, progress: float) -> Pose:
    phase = index * 0.21
    side = 1 if index % 2 == 0 else -1        # neighbours droop toward each other... mostly
    bob = mood.bob_px * math.sin(2 * math.pi * (progress * mood.bob_cycles + phase))
    sway = mood.sway_deg * math.sin(2 * math.pi * (progress + phase))
    return Pose(math.radians(side * mood.tilt_deg + sway), 0, mood.sink_px + bob)


def posed(pixels: np.ndarray, pose: Pose) -> np.ndarray:
    """Rotate/shift premultiplied pixels; PIL wants the output-to-input mapping."""
    c, s = math.cos(-pose.angle), math.sin(-pose.angle)
    px, py = PIVOT[0] + pose.dx, PIVOT[1] + pose.dy
    a, b, d, e = c, -s, s, c
    coeffs = (a, b, PIVOT[0] - a * px - b * py, d, e, PIVOT[1] - d * px - e * py)
    channels = [Image.fromarray(np.ascontiguousarray(pixels[..., i]), "F")
                .transform((CELL_W, HEIGHT), Image.AFFINE, coeffs, Image.BICUBIC) for i in range(4)]
    return np.clip(np.dstack([np.asarray(ch) for ch in channels]), 0, 1)


# ---------- painted effects (opaque-ish, drawn over the head) ----------

def paint_soft(pixels: np.ndarray, centre, sigma: float, colour, strength: float, only_on_head: bool):
    ys, xs = np.mgrid[0:HEIGHT, 0:CELL_W].astype(np.float32)
    amount = strength * np.exp(-((xs - centre[0]) ** 2 + (ys - centre[1]) ** 2) / (2 * sigma * sigma))
    if only_on_head:
        amount *= pixels[..., 3]
    colour = np.asarray(colour, np.float32) / 255
    pixels[..., :3] = pixels[..., :3] * (1 - amount[..., None]) + colour * amount[..., None] * \
        (pixels[..., 3:] if only_on_head else 1)
    if not only_on_head:
        pixels[..., 3] = amount + pixels[..., 3] * (1 - amount)


def sweat_drop_layer(tip, size: float, opacity: float) -> np.ndarray:
    """A small cartoon teardrop (point up) as premultiplied RGBA, supersampled for smooth edges."""
    s = SUPERSAMPLE
    image = Image.new("RGBA", (CELL_W * s, HEIGHT * s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    x, y, r = tip[0] * s, tip[1] * s, size * s
    body = [(x - r, y + 1.6 * r), (x + r, y + 3.6 * r)]
    draw.polygon([(x, y), (x - r * 0.95, y + 2.4 * r), (x + r * 0.95, y + 2.4 * r)], fill=SWEAT_OUTLINE)
    draw.ellipse([(body[0][0] - s * 0.6, body[0][1] - s * 0.6), (body[1][0] + s * 0.6, body[1][1] + s * 0.6)],
                 fill=SWEAT_OUTLINE)
    draw.polygon([(x, y + s * 0.9), (x - r * 0.7, y + 2.4 * r), (x + r * 0.7, y + 2.4 * r)], fill=SWEAT)
    draw.ellipse(body, fill=SWEAT)
    draw.ellipse([(x - r * 0.45, y + 2.2 * r), (x - r * 0.05, y + 2.7 * r)], fill=WHITE)
    small = image.resize((CELL_W, HEIGHT), Image.LANCZOS)
    rgba = np.asarray(small, np.float32) / 255
    rgba[..., 3] *= opacity
    rgba[..., :3] *= rgba[..., 3:]
    return rgba


def over(pixels: np.ndarray, layer: np.ndarray) -> np.ndarray:
    return layer + pixels * (1 - layer[..., 3:])


def add_sweat(pixels: np.ndarray, head: Head, mood: Mood, pose: Pose, index: int, progress: float):
    for drop in range(mood.sweat_drops):
        side = 1 if (drop + index) % 2 == 0 else -1
        age = (progress * (1 + drop) + index * 0.37 + drop * 0.5) % 1.0
        temple = (PIVOT[0] + side * head.width * 0.40, HEIGHT - HEAD_HEIGHT + 12)
        tip = pose.apply((temple[0] + side * age * 1.5, temple[1] + age * 12))
        opacity = min(1.0, age * 6) * min(1.0, (1 - age) * 3)
        pixels[:] = over(pixels, sweat_drop_layer(tip, 1.6, opacity))


def add_blush(pixels: np.ndarray, head: Head, mood: Mood, pose: Pose):
    if mood.blush <= 0:
        return
    for x, y in head.eyes:
        paint_soft(pixels, pose.apply((x, y + 5)), 2.2, BLUSH, mood.blush, only_on_head=True)


# ---------- light effects (additive glow) ----------

def sputter_factor(mood: Mood, progress: float, index: int) -> float:
    """1 = full fire; dips toward 0 now and then when the fire is sputtering."""
    if mood.sputter <= 0:
        return 1.0
    wave = 0.5 + 0.5 * math.sin(2 * math.pi * (progress * 3 + index * 0.3)) * math.sin(2 * math.pi * (progress * 7 + index))
    return 1 - mood.sputter * (1 - wave) ** 0.5


def burning_eye(light, origin, outward: int, glow, mood: Mood, progress: float, power: float):
    pulse = (0.85 + 0.15 * math.sin(2 * math.pi * progress * 3)) * power
    add_blob(light, origin, 3.4, glow, 0.22 * pulse)
    add_blob(light, origin, 1.2, mix(WHITE, glow, 0.7), 0.45 * pulse)
    particles = 18
    for i in range(particles):
        seed = i / particles
        age = (progress * mood.fire_cycles + seed) % 1.0
        flicker = math.sin(2 * math.pi * (progress * 4 + seed * 2.7)) * 1.6 * age
        position = (origin[0] + outward * (3.0 + age * mood.fire_length),
                    origin[1] - age * mood.fire_length * 0.5 + flicker)
        heat = (1 - age) ** 1.4
        colour = mix(WHITE, glow, min(1, 0.4 + age * 2.5))
        add_blob(light, position, 0.6 + 1.5 * (1 - age), colour, mood.fire_strength * heat * power)


def add_steam(light, head: Head, mood: Mood, pose: Pose, index: int, progress: float):
    for puff in range(mood.steam_puffs):
        age = (progress * 2 + puff / max(1, mood.steam_puffs) + index * 0.13) % 1.0
        side = (-1, 0.2, 1)[puff % 3]
        start = (PIVOT[0] + side * head.width * 0.3, HEIGHT - HEAD_HEIGHT + 4)
        drift = math.sin(2 * math.pi * (age + puff * 0.3)) * 1.5
        centre = pose.apply((start[0] + drift + side * age * 4, start[1] - age * 9))
        fade = min(1.0, age * 5) * (1 - age)
        add_blob(light, centre, 1.6 + 2.8 * age, (235, 240, 255), 0.9 * fade)


# ---------- frames ----------

def render_head(head: Head, mood: Mood, index: int, progress: float) -> np.ndarray:
    pose = pose_for(mood, index, progress)
    pixels = posed(head.pixels, pose)
    add_blush(pixels, head, mood, pose)
    add_sweat(pixels, head, mood, pose, index, progress)

    light = np.zeros_like(pixels)
    power = sputter_factor(mood, progress, index)
    for eye, outward in zip(head.eyes, (-1, 1)):
        burning_eye(light, pose.apply(eye), outward, head.glow, mood, progress, power)
    add_steam(light, head, mood, pose, index, progress)
    return composite_array(pixels, light)


def composite_array(pixels: np.ndarray, light: np.ndarray) -> np.ndarray:
    return np.asarray(composite(pixels, light))


def render_sheet(heads: list, mood: Mood) -> Image.Image:
    width = CELL_W * len(heads)
    sheet = Image.new("RGBA", (width, HEIGHT * FRAME_COUNT))
    for frame in range(FRAME_COUNT):
        progress = frame / FRAME_COUNT
        row = np.concatenate([render_head(h, mood, i, progress) for i, h in enumerate(heads)], axis=1)
        sheet.paste(Image.fromarray(row, "RGBA"), (0, frame * HEIGHT))
    return sheet


def main(config_path: str, output_stem: str):
    config = Path(config_path)
    heads = [load_head(entry, config.parent, HEAD_HEIGHT) for entry in json.loads(config.read_text())]
    stem = Path(output_stem)
    for mood in MOODS:
        render_sheet(heads, mood).save(f"{stem}_{mood.name}.png")
    stem.with_suffix(".json").write_text(json.dumps({
        "frameWidth": CELL_W * len(heads), "frameHeight": HEIGHT, "frameCount": FRAME_COUNT,
        "frameMs": FRAME_MS, "moods": [mood.name for mood in MOODS]}))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
