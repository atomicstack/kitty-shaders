# kitty-shaders

## wow-confetti

A kitty (0.49+) custom shader port of the "wow mode" confetti spray from
[hyperpower](https://github.com/vercel/hyperpower). Each cursor move sprays
5–10 coloured 3×3 particles from the cursor. They arc under gravity and fade out.
The screen shake is not ported.

the confetti palette omits pure black, so each burst starts with red. the gray
entry is retained. `USE_CURSOR_COLOR` still uses the configured cursor colour.

### Install

```sh
mkdir -p ~/.config/kitty/shaders
ln -s $PWD/wow-confetti.pipeline $PWD/wow-confetti.slang ~/.config/kitty/shaders/
```

Add to `kitty.conf`:

```
cursor_trail 1
cursor_trail_start_threshold 0
custom_shaders wow-confetti
```

Cursor movement only reaches shaders through the cursor trail data, so
`cursor_trail` must be on. The pipeline subscribes to `cursor-trail-move`,
which hides kitty's built-in trail. The threshold of 0 makes single-character
moves (typing) spray too.

### Tuning

Override any `static const` at the top of `wow-confetti.slang` from the
pipeline with `var` directives. For example, add these to each group:

```
var float PIXEL_SCALE = 1.0      # non-retina displays
var bool USE_CURSOR_COLOR = true # hyperpower's non-wow mode
```

if changing `FPS`, `PARTICLE_ALPHA_FADEOUT` or `PARTICLE_ALPHA_MIN_THRESHOLD`,
keep `animation_stop` above the particle lifetime with at least one frame of
margin. lifetime in milliseconds is
`1000 * log(PARTICLE_ALPHA_MIN_THRESHOLD) / log(PARTICLE_ALPHA_FADEOUT) / FPS`.
the default 1000ms timer covers the default lifetime of approximately 940ms.

### How it works

- **Stage 0:** reads a ring buffer of spray events (cursor position and spawn
  time) from the bottom row of the `persist` texture. It adds an event when the
  cursor has moved, throttled to 25ms like hyperpower, and writes the result to
  texture `a`. It also saves one bounding box around all live particles.
- **Stage 1:** copies `a` back into `persist`.
- **Stage 2:** draws the particles. Hyperpower's per-frame physics have a
  closed form, so each particle's position and alpha come from its event's age.
  Its random velocity comes from a hash of the event.

### Performance

- Stages 0 and 1 only render a strip in the bottom-left corner, 25% of the
  width and 2% of the height, which is where the state lives. The state needs
  52×1 pixels, so windows must be at least 208 pixels wide and 50 pixels tall.
- Stage 2 must cover the whole screen, but pixels outside the particle
  bounding box return after two texture reads.
- velocity generation stops at the burst's actual particle count, and fade
  is calculated only for pixels that hit a particle.
- Set `var bool DEBUG_BOUNDS = true` in the stage 2 group to tint that box.

Mean GPU use for a full-screen window (4112×2514) on an M3 Max, running
`while true; do printf "foo "; sleep 0.001; done`:

| shader | `sync_to_monitor no` | `sync_to_monitor yes` |
|---|---|---|
| none | 71% | 56% |
| first version (3 full-screen passes) | 98% | 64% |
| current | 71% | 58% |

### Checking it compiles

```sh
kitty +launch check.py wow-confetti.pipeline
```

check the palette and animation lifetime with:

```sh
python3 -m unittest -v test_confetti.py
```
