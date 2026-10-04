"""check the confetti palette and animation lifetime without launching kitty."""

import math
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent


class ConfettiSettingsTest(unittest.TestCase):
    def test_palette_has_no_black_particles(self):
        source = (ROOT / "wow-confetti.slang").read_text()
        palette = re.search(r"PALETTE\[\d+\]\s*=\s*\{(.*?)\};", source, re.S)
        self.assertIsNotNone(palette, "could not find the confetti palette")
        colors = [
            tuple(int(channel.strip(), 0) for channel in color.split(","))
            for color in re.findall(r"float3\(([^)]+)\)", palette[1])
        ]
        self.assertTrue(colors, "the confetti palette must not be empty")
        self.assertNotIn((0, 0, 0), colors, "black particles disappear on dark backgrounds")

    def test_animation_stops_soon_after_particles_expire(self):
        source = (ROOT / "wow-confetti.slang").read_text()
        pipeline = (ROOT / "wow-confetti.pipeline").read_text()

        def setting(name):
            return float(re.search(rf"static const float {name} = ([\d.]+);", source)[1])

        lifetime_ms = (
            1000 * math.log(setting("PARTICLE_ALPHA_MIN_THRESHOLD"))
            / math.log(setting("PARTICLE_ALPHA_FADEOUT")) / setting("FPS")
        )
        stop_ms = int(re.search(r"animation_stop\s+(\d+)", pipeline)[1])
        step_ms = int(re.search(r"animation_step\s+(\d+)", pipeline)[1])
        self.assertGreaterEqual(stop_ms, lifetime_ms + step_ms, "allow a frame to clear expired particles")
        self.assertLessEqual(stop_ms, lifetime_ms + 100, "avoid scheduling a long invisible animation tail")


if __name__ == "__main__":
    unittest.main()
