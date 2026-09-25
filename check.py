# compile a custom shader pipeline exactly as kitty would, without loading it
# into a running kitty. usage: kitty +launch check.py wow-confetti.pipeline

import os
import sys
import tempfile

from kitty.shaders.slang import build_custom_shader_pipeline_glsl, clear_caches, parse_pipeline_definition, pipeline_definition


def main() -> None:
    for name in sys.argv[1:]:
        path = os.path.abspath(name)
        lines, pipeline_dir = pipeline_definition(path)
        pipeline = parse_pipeline_definition(lines, os.path.basename(path), pipeline_dir)
        with tempfile.TemporaryDirectory() as cache_dir:
            clear_caches()
            vert, frag, _ = build_custom_shader_pipeline_glsl(pipeline, cache_dir=cache_dir)
        print(f'ok: {name} compiled ({len(vert)} bytes vertex, {len(frag)} bytes fragment glsl)')


main()
