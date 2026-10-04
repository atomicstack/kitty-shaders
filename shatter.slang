#language slang 2026
// shatter — a sibling of wow-confetti. every time the cursor moves, 6-10 white
// squares burst out of it, arc under gravity and land on the bottom edge of
// the cursor's text row. on impact each square breaks into its four quarters
// (half the side length each), which pop apart, settle on the line and fade.
//
// the shader runs in three stages (see shatter.pipeline):
//
//   STAGE 0: read the event ring buffer from t.persist, record a new burst
//            if the cursor moved, write the new ring buffer to t.a
//   STAGE 1: copy t.a back into t.persist for the next frame
//   STAGE 2: draw every square and shard of every live event
//
// stages 0 and 1 only render a small strip at the bottom-left of the screen
// (the pipeline gives them a viewport), since that is where the state lives.
//
// nothing is simulated step by step. in css pixels, y down, a square launched
// with velocity v is at o + v n + (0, g n (n + 1) / 2) after n frames, the
// closed form of hyperpower's per-frame update. the frame it lands on the
// floor solves a quadratic, and the shards follow the same closed form from
// the landing point.
//
// the state lives in the bottom two rows of the persist texture (RGBA16
// unorm, so each channel stores a 16 bit value):
//
//   row 0, texel 0:      last spawn time (hi, lo), write index
//   row 0, texel 1:      last update time (hi, lo), unused
//   row 0, texel 2:      bounding box of everything live: min x, min y (UV)
//   row 0, texel 3:      bounding box of everything live: max x, max y (UV)
//   row 0, texel 4 + i:  slot i: cursor centre x, y (UV), spawn time mod 64s
//   row 1, texel 4 + i:  slot i: floor y (UV) of the cursor's row
//
// requires cursor_trail to be enabled in kitty.conf, since cursor movement is
// only reported to shaders via the cursor trail data.

import kitty_custom_shader_types;

// --- tunables (override with `var` directives in the pipeline file) ---

// size of one css pixel in device pixels. 2 for retina displays.
static const float PIXEL_SCALE = 2.0;
// the physics advance once per 60fps frame, like hyperpower.
static const float FPS = 60.0;
// colour of the squares and shards, in sRGB.
static const float3 COLOR = float3(1.0, 1.0, 1.0);
// side of a square in css pixels. shards are half this size.
static const float SQUARE_SIZE = 3.0;
static const float GRAVITY = 0.2;
// launch speed range, css pixels per frame.
static const float SPEED_MIN = 1.5;
static const float SPEED_MAX = 4.0;
// squares launch upwards, at least this many radians above horizontal.
static const float LAUNCH_MIN_ANGLE = 0.2;
// how long shards live after impact, in frames.
static const float SHARD_FRAMES = 24.0;
// shard velocity ranges on impact. x points away from the square's centre.
static const float2 SHARD_VELOCITY_X = float2(0.4, 1.4);
static const float2 SHARD_VELOCITY_Y = float2(0.5, 1.8);
// fraction of the square's horizontal velocity the shards keep.
static const float SHARD_INHERIT_X = 0.25;
// minimum seconds between bursts.
static const float SPAWN_THROTTLE = 0.03;
// longest a burst can live, in seconds. must cover the worst flight plus
// SHARD_FRAMES for the tallest cells in use, and stay below animation_stop.
static const float MAX_LIFETIME = 1.3;
// tint the region stage 2 draws in, to check nothing gets clipped.
static const bool DEBUG_BOUNDS = false;

// internal
static const int STAGE = 0;
// number of bursts remembered. 48 * 30ms outlives MAX_LIFETIME.
static const int NUM_SLOTS = 48;
static const int BOX_MIN = 2;
static const int BOX_MAX = 3;
static const int SLOT_BASE = 4;
static const float TIME_WRAP = 64.0;
static const int MIN_PARTICLES = 6;
static const int MAX_PARTICLES = 10;

// --- helpers ---

static float3
to_srgb(float3 x) {
    float3 lower = 12.92 * x;
    float3 upper = 1.055 * pow(max(x, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
    return lerp(lower, upper, step(float3(0.0031308), x));
}

static float3
to_linear(float3 x) {
    float3 lower = x / 12.92;
    float3 upper = pow(max((x + 0.055) / 1.055, float3(0.0)), float3(2.4));
    return lerp(lower, upper, step(float3(0.04045), x));
}

static uint
pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// uniform random float in [0, 1), advancing the seed.
static float
rand(inout uint seed) {
    seed = pcg(seed);
    return float(seed) / 4294967296.0;
}

static float2
texel_uv(int2 i, float2 vp) {
    return (float2(i) + 0.5) / vp;
}

static float
unorm16(float v) {
    return round(saturate(v) * 65535.0);
}

// full precision time split into two 16 bit channels: 64s units and a
// fraction of 64s (~1ms resolution), good for ~48 days of kitty uptime.
static float2
encode_time(float t) {
    float q = max(t, 0.0) / TIME_WRAP;
    return float2(floor(q) / 65535.0, fract(q));
}

static float
decode_time(float2 v) {
    return (unorm16(v.x) + v.y) * TIME_WRAP;
}

// age of a slot whose spawn time was stored modulo TIME_WRAP.
static float
slot_age(float now, float stored) {
    float age = now - stored * TIME_WRAP;
    return age - TIME_WRAP * floor(age / TIME_WRAP);
}

static float2
uv_to_css(float2 uv, float2 vp) {
    return float2(uv.x, 1.0 - uv.y) * vp / PIXEL_SCALE;
}

static float2
css_to_uv(float2 css, float2 vp) {
    float2 uv = css * PIXEL_SCALE / vp;
    return float2(uv.x, 1.0 - uv.y);
}

// frames until a square launched from height `origin_y` with vertical
// velocity `vy` rests on the floor, i.e. the positive root of
// g/2 n^2 + (vy + g/2) n + (origin_y + half size - floor_y) = 0.
static float
landing_frame(float origin_y, float vy, float floor_y) {
    float a = GRAVITY * 0.5;
    float b = vy + GRAVITY * 0.5;
    float c = min(origin_y + SQUARE_SIZE * 0.5 - floor_y, 0.0);
    return (-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a);
}

// every burst is gone once its highest-flying square (launched straight up
// at SPEED_MAX, the longest flight) has landed and its shards have faded.
static float
event_frames(float origin_y, float floor_y) {
    return landing_frame(origin_y, -SPEED_MAX, floor_y) + SHARD_FRAMES;
}

// bounding box, in css pixels (y down), of every square and shard a burst can
// have n frames after it spawned. x: squares move at most SPEED_MAX per
// frame, and shards more slowly. y: nothing goes below the floor; squares
// rise at most SPEED_MAX per frame up to their peak, and shards pop at most
// SHARD_VELOCITY_Y.y^2 / 2g above it.
static void
event_bounds(float2 origin, float floor_y, float n, out float2 lo, out float2 hi) {
    float margin = SQUARE_SIZE + 1.0;
    float peak = SPEED_MAX * SPEED_MAX / (2.0 * GRAVITY);
    float shard_pop = SHARD_VELOCITY_Y.y * SHARD_VELOCITY_Y.y / (2.0 * GRAVITY) + SQUARE_SIZE;
    float top = min(origin.y - min(SPEED_MAX * n, peak), floor_y - shard_pop);
    lo = float2(origin.x - SPEED_MAX * n, top) - margin;
    hi = float2(origin.x + SPEED_MAX * n, floor_y) + margin;
}

// --- stage 0: record cursor moves into the ring buffer ---

struct Update {
    bool stale, spawn;
    int idx;
    float now, last_spawn, moved_at;
};

static Update
begin_update(KittyTextures t, KittyCustomShaderData d, float2 vp) {
    float4 head = t.persist.Sample(texel_uv(int2(0, 0), vp));
    float4 tick = t.persist.Sample(texel_uv(int2(1, 0), vp));
    Update u;
    u.now = d.timestamp;

    // the group only runs while animating: if the last update is older than
    // any burst can live, every stored slot is dead and may even look alive
    // again once its mod-64s timestamp wraps, so start afresh.
    float last_update = decode_time(tick.xy);
    u.stale = u.now - last_update > MAX_LIFETIME || last_update > u.now + 1.0;

    u.last_spawn = u.stale ? 0.0 : decode_time(head.xy);
    u.idx = u.stale ? 0 : int(unorm16(head.z)) % NUM_SLOTS;

    u.moved_at = d.cursor_trail_change_time;
    u.spawn = d.cursor_trail_state > 0.5 && u.moved_at > 0.0 && u.now - u.moved_at < 0.25 &&
              u.moved_at - u.last_spawn >= SPAWN_THROTTLE;
    if (u.spawn) {
        u.idx = (u.idx + 1) % NUM_SLOTS;
        u.last_spawn = u.moved_at;
    }
    return u;
}

struct Slot {
    float3 ev;     // centre x, centre y (UV), spawn time mod 64s. y <= 0: empty
    float floor_y; // UV
};

static Slot
empty_slot() {
    Slot s;
    s.ev = float3(0.0);
    s.floor_y = 0.0;
    return s;
}

static Slot
read_slot(KittyTexture tex, int slot, float2 vp) {
    Slot s;
    s.ev = tex.Sample(texel_uv(int2(SLOT_BASE + slot, 0), vp)).xyz;
    s.floor_y = tex.Sample(texel_uv(int2(SLOT_BASE + slot, 1), vp)).x;
    return s;
}

static bool
slot_alive(Slot s, float now, float2 vp) {
    if (s.ev.y <= 0.0) return false;
    float2 origin = uv_to_css(s.ev.xy, vp);
    float floor_y = uv_to_css(float2(0.0, s.floor_y), vp).y;
    return slot_age(now, s.ev.z) * FPS <= event_frames(origin.y, floor_y);
}

// the new value of a slot this frame.
static Slot
updated_slot(KittyTextures t, KittyCustomShaderData d, Update u, int slot, float2 vp) {
    if (u.spawn && slot == u.idx) {
        // edges: .x=left .y=right .z=top .w=bottom, in UV
        float4 e = d.cursor_trail_edge;
        Slot s;
        s.ev = float3((e.x + e.y) * 0.5, (e.z + e.w) * 0.5, fract(u.moved_at / TIME_WRAP));
        s.floor_y = e.w;
        return s;
    }
    if (u.stale) return empty_slot();
    Slot s = read_slot(t.persist, slot, vp);
    return slot_alive(s, u.now, vp) ? s : empty_slot();
}

static float4
update_state(KittyTextures t, KittyCustomShaderData d, int2 texel, float2 vp) {
    Update u = begin_update(t, d, vp);
    if (texel.y == 1) {
        if (texel.x < SLOT_BASE) return float4(0.0, 0.0, 0.0, 1.0);
        return float4(updated_slot(t, d, u, texel.x - SLOT_BASE, vp).floor_y, 0.0, 0.0, 1.0);
    }
    if (texel.x == 0) return float4(encode_time(u.last_spawn), float(u.idx) / 65535.0, 1.0);
    if (texel.x == 1) return float4(encode_time(u.now), 0.0, 1.0);
    if (texel.x >= SLOT_BASE) return float4(updated_slot(t, d, u, texel.x - SLOT_BASE, vp).ev, 1.0);

    // union of the bounding boxes of all live bursts, in css pixels
    float2 lo = float2(1e9), hi = float2(-1e9);
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        Slot s = updated_slot(t, d, u, slot, vp);
        if (s.ev.y <= 0.0) continue;
        float2 elo, ehi;
        event_bounds(uv_to_css(s.ev.xy, vp), uv_to_css(float2(0.0, s.floor_y), vp).y,
                     slot_age(u.now, s.ev.z) * FPS, elo, ehi);
        lo = min(lo, elo);
        hi = max(hi, ehi);
    }
    // nothing alive: an empty box, min above max, so stage 2 skips every pixel
    if (lo.x > hi.x) return texel.x == BOX_MIN ? float4(1.0, 1.0, 0.0, 1.0) : float4(0.0, 0.0, 0.0, 1.0);
    // y flips going to UV, so css max y becomes UV min y. widen by a texel
    // either side to absorb the 16 bit quantisation.
    float2 uv_lo = css_to_uv(float2(lo.x, hi.y), vp) - 1.0 / vp;
    float2 uv_hi = css_to_uv(float2(hi.x, lo.y), vp) + 1.0 / vp;
    return float4(saturate(texel.x == BOX_MIN ? uv_lo : uv_hi), 0.0, 1.0);
}

// --- stage 2: draw the squares and shards ---

// does the device pixel p fall in a square of side `size` css pixels centred
// on css position q? the corner snaps to whole device pixels.
static bool
in_square(float2 p, float2 q, float size) {
    float2 corner = round((q - size * 0.5) * PIXEL_SCALE);
    float2 far = corner + round(size * PIXEL_SCALE);
    return all(p >= corner) && all(p < far);
}

// alpha of whatever part of one burst covers device pixel p, n frames in.
static float
draw_burst(float2 p, float2 origin, float floor_y, float n, uint seed) {
    int count = MIN_PARTICLES + int(round(rand(seed) * float(MAX_PARTICLES - MIN_PARTICLES)));
    float alpha = 0.0;
    for (int i = 0; i < count; i++) {
        // always draw the same randoms per square, hit or not, so the
        // sequence stays in step for the squares after it.
        float angle = lerp(3.14159265 + LAUNCH_MIN_ANGLE, 6.28318531 - LAUNCH_MIN_ANGLE, rand(seed));
        float speed = lerp(SPEED_MIN, SPEED_MAX, rand(seed));
        float2 vel = float2(cos(angle), sin(angle)) * speed;
        uint shard_seed = pcg(seed);

        float land = landing_frame(origin.y, vel.y, floor_y);
        if (n < land) {
            float2 q = origin + vel * n + float2(0.0, GRAVITY * n * (n + 1.0) * 0.5);
            if (in_square(p, q, SQUARE_SIZE)) alpha = 1.0;
            continue;
        }

        float m = n - land;
        if (m > SHARD_FRAMES) continue;
        float fade = 1.0 - m / SHARD_FRAMES;
        float2 at = float2(origin.x + vel.x * land, floor_y - SQUARE_SIZE * 0.5);
        float quarter = SQUARE_SIZE * 0.25;
        for (int j = 0; j < 4; j++) {
            float2 side = float2((j & 1) == 0 ? -1.0 : 1.0, (j & 2) == 0 ? -1.0 : 1.0);
            float2 start = at + side * quarter;
            float2 v = float2(side.x * lerp(SHARD_VELOCITY_X.x, SHARD_VELOCITY_X.y, rand(shard_seed)) + vel.x * SHARD_INHERIT_X,
                              -lerp(SHARD_VELOCITY_Y.x, SHARD_VELOCITY_Y.y, rand(shard_seed)));
            float2 q = start + v * m + float2(0.0, GRAVITY * m * (m + 1.0) * 0.5);
            // shards come to rest on the floor instead of falling through it
            q.y = min(q.y, floor_y - quarter);
            if (in_square(p, q, SQUARE_SIZE * 0.5)) alpha = max(alpha, fade * fade);
        }
    }
    return alpha;
}

static float4
draw_particles(float4 color, KittyTextures t, KittyCustomShaderData d, float2 vp) {
    float2 box_lo = t.a.Sample(texel_uv(int2(BOX_MIN, 0), vp)).xy;
    float2 box_hi = t.a.Sample(texel_uv(int2(BOX_MAX, 0), vp)).xy;
    if (any(t.pos < box_lo) || any(t.pos > box_hi)) return color;
    if (DEBUG_BOUNDS) color.rgb = lerp(color.rgb, float3(0.0, 0.05, 0.2), 0.5);

    float now = d.timestamp;
    // this pixel in css pixels (y down) and in device pixels (y down)
    float2 p_css = uv_to_css(t.pos, vp);
    float2 p = floor(float2(t.pos.x, 1.0 - t.pos.y) * vp);

    float alpha = 0.0;
    for (int slot = 0; slot < NUM_SLOTS && alpha < 1.0; slot++) {
        Slot s = read_slot(t.a, slot, vp);
        if (s.ev.y <= 0.0) continue;
        float2 origin = uv_to_css(s.ev.xy, vp);
        float floor_y = uv_to_css(float2(0.0, s.floor_y), vp).y;
        float n = slot_age(now, s.ev.z) * FPS;
        if (n > event_frames(origin.y, floor_y)) continue;
        float2 lo, hi;
        event_bounds(origin, floor_y, n, lo, hi);
        if (any(p_css < lo) || any(p_css > hi)) continue;
        uint seed = pcg(uint(unorm16(s.ev.z)) ^ pcg(uint(unorm16(s.ev.x)) ^ pcg(uint(unorm16(s.ev.y)))));
        alpha = max(alpha, draw_burst(p, origin, floor_y, n, seed));
    }
    if (alpha <= 0.0) return color;
    // blend in sRGB space, like a canvas would
    return float4(to_linear(lerp(to_srgb(color.rgb), COLOR, alpha)), max(color.a, alpha));
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 vp = float2(d.viewport_size_pixels);
    if (STAGE == 2) return draw_particles(color, t, d, vp);

    // stages 0 and 1 render into a viewport anchored at the bottom-left, and
    // t.pos spans [0, 1] across it. kitty sizes it in whole pixels, truncating.
    float2 group_px = floor(t.viewport.zw * vp + 1e-3);
    int2 px = int2(floor(t.pos * group_px));
    if (px.y > 1 || px.x >= SLOT_BASE + NUM_SLOTS) return float4(0.0, 0.0, 0.0, 1.0);
    if (STAGE == 0) return update_state(t, d, px, vp);
    return float4(t.a.Sample(texel_uv(px, vp)).xyz, 1.0);
}
