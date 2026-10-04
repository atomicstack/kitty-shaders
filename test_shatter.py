"""check the shatter physics, bounds and timing without launching kitty.

the shader's closed-form maths is mirrored here and compared against a
frame-by-frame simulation, using the constants from shatter.slang.
"""

import math
import os
from pathlib import Path
import random
import re
import unittest


ROOT = Path(__file__).resolve().parent
SOURCE = Path(os.environ.get("SHATTER_SLANG", ROOT / "shatter.slang")).read_text()
PIPELINE = (ROOT / "shatter.pipeline").read_text()


def const(name):
    match = re.search(rf"static const (?:float|int) {name} = ([^;]+);", SOURCE)
    if match is None:
        raise KeyError(name)
    return float(match[1])


def const2(name):
    match = re.search(rf"static const float2 {name} = float2\(([^,]+),([^)]+)\);", SOURCE)
    return float(match[1]), float(match[2])


G = const("GRAVITY")
SPEED_MIN, SPEED_MAX = const("SPEED_MIN"), const("SPEED_MAX")
SIZE = const("SQUARE_SIZE")
SHARD_FRAMES = const("SHARD_FRAMES")
SHARD_VX, SHARD_VY = const2("SHARD_VELOCITY_X"), const2("SHARD_VELOCITY_Y")
SHARD_INHERIT_X = const("SHARD_INHERIT_X")
ANGLE = const("LAUNCH_MIN_ANGLE")
FPS = const("FPS")
MAX_LIFETIME = const("MAX_LIFETIME")

# the floor sits half a cell below the cursor centre. cover cells from 8 to
# 60 css pixels tall (a 120 device pixel cell on a retina display).
DROPS = (4.0, 9.0, 18.0, 30.0)


def landing_frame(origin_y, vy, floor_y):
    a, b = G / 2, vy + G / 2
    c = min(origin_y + SIZE / 2 - floor_y, 0.0)
    return (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)


def event_frames(origin_y, floor_y):
    return landing_frame(origin_y, -SPEED_MAX, floor_y) + SHARD_FRAMES


def event_bounds(origin, floor_y, n):
    margin = SIZE + 1
    peak = SPEED_MAX**2 / (2 * G)
    shard_pop = SHARD_VY[1] ** 2 / (2 * G) + SIZE
    top = min(origin[1] - min(SPEED_MAX * n, peak), floor_y - shard_pop)
    return (origin[0] - SPEED_MAX * n - margin, top - margin), (origin[0] + SPEED_MAX * n + margin, floor_y + margin)


def random_square(rng):
    angle = rng.uniform(math.pi + ANGLE, 2 * math.pi - ANGLE)
    speed = rng.uniform(SPEED_MIN, SPEED_MAX)
    return math.cos(angle) * speed, math.sin(angle) * speed


def pieces(origin, floor_y, vel, shard_vels, n):
    """css centres and sizes of whatever one square has become after n frames."""
    land = landing_frame(origin[1], vel[1], floor_y)
    if n < land:
        return [((origin[0] + vel[0] * n, origin[1] + vel[1] * n + G * n * (n + 1) / 2), SIZE)]
    m = n - land
    if m > SHARD_FRAMES:
        return []
    at = (origin[0] + vel[0] * land, floor_y - SIZE / 2)
    quarter = SIZE / 4
    out = []
    for j, (svx, svy) in enumerate(shard_vels):
        sx, sy = (-1 if j & 1 == 0 else 1), (-1 if j & 2 == 0 else 1)
        vx = sx * svx + vel[0] * SHARD_INHERIT_X
        x = at[0] + sx * quarter + vx * m
        y = at[1] + sy * quarter - svy * m + G * m * (m + 1) / 2
        out.append(((x, min(y, floor_y - quarter)), SIZE / 2))
    return out


class ShatterPhysicsTest(unittest.TestCase):
    def test_landing_frame_matches_frame_by_frame_simulation(self):
        rng = random.Random(1)
        for drop in DROPS:
            for _ in range(200):
                vx, vy = random_square(rng)
                y, v, frame = -drop, vy, 0
                # hyperpower's update: accelerate, then move
                while y + SIZE / 2 < 0:
                    v += G
                    y += v
                    frame += 1
                land = landing_frame(-drop, vy, 0.0)
                self.assertTrue(frame - 1 < land <= frame, f"drop {drop}, vy {vy}: sim {frame}, formula {land}")

    def test_slowest_landing_is_straight_up_at_full_speed(self):
        rng = random.Random(2)
        for drop in DROPS:
            worst = landing_frame(-drop, -SPEED_MAX, 0.0)
            for _ in range(500):
                self.assertLessEqual(landing_frame(-drop, random_square(rng)[1], 0.0), worst + 1e-9)

    def test_bounds_contain_every_square_and_shard(self):
        rng = random.Random(3)
        for drop in DROPS:
            origin, floor_y = (500.0, 300.0), 300.0 + drop
            for _ in range(100):
                vel = random_square(rng)
                shard_vels = [(rng.uniform(*SHARD_VX), rng.uniform(*SHARD_VY)) for _ in range(4)]
                n = 0.0
                while n <= event_frames(origin[1], floor_y):
                    lo, hi = event_bounds(origin, floor_y, n)
                    for (x, y), size in pieces(origin, floor_y, vel, shard_vels, n):
                        half = size / 2
                        self.assertGreaterEqual(x - half, lo[0], f"clipped left at n={n}")
                        self.assertLessEqual(x + half, hi[0], f"clipped right at n={n}")
                        self.assertGreaterEqual(y - half, lo[1], f"clipped top at n={n}")
                        self.assertLessEqual(y + half, hi[1], f"clipped bottom at n={n}")
                    n += 0.25

    def test_shards_never_sink_below_the_floor(self):
        rng = random.Random(4)
        origin, floor_y = (0.0, 0.0), 9.0
        for _ in range(100):
            vel = random_square(rng)
            shard_vels = [(rng.uniform(*SHARD_VX), rng.uniform(*SHARD_VY)) for _ in range(4)]
            for step in range(400):
                for (_, y), size in pieces(origin, floor_y, vel, shard_vels, step * 0.25):
                    self.assertLessEqual(y + size / 2, floor_y + 1e-9)


class ShatterTimingTest(unittest.TestCase):
    def test_max_lifetime_covers_the_longest_burst(self):
        for drop in DROPS:
            frames = event_frames(-drop, 0.0)
            self.assertGreaterEqual(MAX_LIFETIME, frames / FPS, f"a {drop} css px drop lives {frames / FPS:.2f}s")

    def test_ring_buffer_outlives_every_burst(self):
        self.assertGreaterEqual(const("NUM_SLOTS") * const("SPAWN_THROTTLE"), MAX_LIFETIME)

    def test_animation_outlasts_max_lifetime(self):
        stop_ms = int(re.search(r"animation_stop\s+(\d+)", PIPELINE)[1])
        step_ms = int(re.search(r"animation_step\s+(\d+)", PIPELINE)[1])
        self.assertGreaterEqual(stop_ms, MAX_LIFETIME * 1000 + step_ms, "allow a frame to clear the last burst")
        self.assertLessEqual(stop_ms, MAX_LIFETIME * 1000 + 100, "avoid a long invisible animation tail")


if __name__ == "__main__":
    unittest.main()
