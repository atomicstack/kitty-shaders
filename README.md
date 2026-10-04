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
  texture `a`. it also packs one bounding box around all live particles into
  a single rgba16 texel, compensating for kitty's output premultiplication.
- **stage 1:** copies `a` back into `persist` and uses spare strip texels to
  cache which events can affect each 32×32 device-pixel tile. if the strip is
  too small for the cache, drawing falls back to checking the events directly.
- **Stage 2:** draws the particles. Hyperpower's per-frame physics have a
  closed form, so each particle's position and alpha come from its event's age.
  Its random velocity comes from a hash of the event.

### Performance

- Stages 0 and 1 only render a strip in the bottom-left corner, 25% of the
  width and 2% of the height, which is where the state lives. The state needs
  51×1 pixels, so windows must be at least 204 pixels wide and 50 pixels tall.
- Stage 2 must cover the whole screen, but pixels outside the particle
  bounding box return after one state texture read, in addition to kitty's
  backbuffer read.
- velocity generation stops at the burst's actual particle count, and fade
  is calculated only for pixels that hit a particle.
- tile masks reject unrelated events before fetching their state. particle
  coverage is kept in a bit mask instead of a dynamically indexed velocity
  array; blending still follows the original order.
- Set `var bool DEBUG_BOUNDS = true` in the stage 2 group to tint that box.

previous measurements, before the packed bounds, shorter timer and particle
loop optimisations: mean gpu use for a full-screen window (4112×2514) on an M3 Max, running
`while true; do printf "foo "; sleep 0.001; done`:

| shader | `sync_to_monitor no` | `sync_to_monitor yes` |
|---|---|---|
| none | 71% | 56% |
| first version (3 full-screen passes) | 98% | 64% |
| strip passes and bounds rejection | 71% | 58% |

an offscreen m3 max benchmark at the same resolution measured approximately
1.70ms per frame before tile culling and 0.61ms with it for frequent cursor
moves spread across the screen. normal simulated typing remained near the
full-screen pass cost (approximately 0.42ms). these are timings around the
complete three-pass shader pipeline, including final srgb conversion, not activity monitor percentages or timings
for rendering the entire terminal. tile culling does not reduce the animation
frame rate or eliminate the full-screen pass.

### Checking it compiles

```sh
kitty +launch check.py wow-confetti.pipeline
```

check the palette and animation lifetime with:

```sh
python3 -m unittest -v test_confetti.py
```

## shatter

A sibling of wow-confetti. Each cursor move bursts 6–10 white 3×3 squares out
of the centre of the cursor. They arc under gravity and land on the bottom edge
of the cursor's text row. On impact, each square breaks into its four quarters
(half the side length each). The quarters pop apart, settle on the line and
fade out over about 0.4s.

### Install

```sh
mkdir -p ~/.config/kitty/shaders
ln -s $PWD/shatter.pipeline $PWD/shatter.slang ~/.config/kitty/shaders/
```

Use the same `cursor_trail` settings as wow-confetti, with
`custom_shaders shatter`.

### Tuning

The tunables at the top of `shatter.slang` include `COLOR` (sRGB),
`SQUARE_SIZE`, `GRAVITY`, the launch speed and angle, and the shard timing and
velocities. If a change makes bursts live longer than `MAX_LIFETIME` (1.3s),
raise it and keep `animation_stop` in the pipeline at least one frame above it.
The tests check this.

### How it works

It uses the same three-pass layout as wow-confetti: a state strip in the
bottom-left corner, and a bounding box so the full-screen pass can skip empty
pixels. Each event also stores its floor, the bottom edge of the cursor's row,
in a second strip row. The strip therefore needs 52×2 pixels, so windows must
be at least 208 pixels wide and 100 pixels tall.

Nothing is simulated step by step:

- **Squares:** a square is at `o + v n + (0, g n (n + 1) / 2)` after `n` frames.
- **Landing:** the landing frame is the positive root of a quadratic.
- **Shards:** they follow the same closed form from the landing point, clamped
  to the floor.

### Checking it

```sh
kitty +launch check.py shatter.pipeline
python3 -m unittest -v test_shatter.py
```

The tests mirror the shader's maths in Python and check several things:

- the landing frame matches a frame-by-frame simulation;
- the bounding box never clips a square or shard;
- shards never sink below the floor;
- `MAX_LIFETIME`, the ring buffer and `animation_stop` cover the longest
  burst.
