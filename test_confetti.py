"""check the confetti palette without launching kitty."""

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


if __name__ == "__main__":
    unittest.main()
