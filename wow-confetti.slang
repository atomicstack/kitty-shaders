#language slang 2026
// wow mode confetti — a port of the particle spray from hyperpower's "wow mode"
// (https://github.com/vercel/hyperpower) to a kitty custom shader. every time
// the cursor moves, 5-10 coloured 3x3 particles are sprayed from its top-left
// corner, fly up, fall under gravity and fade out. the screen shake is not
// ported.
//
// kitty shaders are stateless per pixel, so the shader runs in three stages
// (see wow-confetti.pipeline):
//
//   STAGE 0: read the event ring buffer from t.persist, record a new spray
//            event if the cursor moved, write the new ring buffer to t.a
//   STAGE 1: copy t.a back into t.persist for the next frame
//   STAGE 2: draw every particle of every live event over the terminal
//
// stages 0 and 1 only render a small strip at the bottom-left of the screen
// (the pipeline gives them a viewport), since that is where the state lives.
//
// particles are not simulated step by step: hyperpower's per-frame update
// (vy += g; x += vx; y += vy; alpha *= fade) has a closed form, so each
// particle's position and alpha are derived from the age of its event, and
// its random velocity from a hash of the event.
//
// the state lives in the bottom row of pixels of the persist texture (which
// is RGBA16 unorm, so each channel stores a 16 bit value):
//
//   texel 0:             last spawn time (hi, lo), write index
//   texel 1:             last update time (hi, lo), unused
//   texel 2:             bounding box of all live particles: min x, min y (UV)
//   texel 3:             bounding box of all live particles: max x, max y (UV)
//   texel 4 + i:         slot i: cursor x, cursor y (UV), spawn time mod 64s
//
// stage 2 reads the bounding box first, so pixels away from any confetti
// cost two texture reads.
//
// requires cursor_trail to be enabled in kitty.conf, since cursor movement is
// only reported to shaders via the cursor trail data.

import kitty_custom_shader_types;

// --- tunables (override with `var` directives in the pipeline file) ---

// size of one hyperpower (css) pixel in device pixels. 2 for retina displays.
static const float PIXEL_SCALE = 2.0;
// hyperpower advanced the simulation once per animation frame, assume 60fps.
static const float FPS = 60.0;
static const float PARTICLE_GRAVITY = 0.075;
static const float PARTICLE_ALPHA_FADEOUT = 0.96;
static const float PARTICLE_ALPHA_MIN_THRESHOLD = 0.1;
static const float2 PARTICLE_VELOCITY_RANGE_X = float2(-1.0, 1.0);
static const float2 PARTICLE_VELOCITY_RANGE_Y = float2(-3.5, -1.5);
// minimum seconds between sprays (hyperpower throttles spawning to 25ms).
static const float SPAWN_THROTTLE = 0.025;
// use the cursor colour for every particle (hyperpower's non-wow mode).
static const bool USE_CURSOR_COLOR = false;
// tint the region stage 2 draws in, to check nothing gets clipped.
static const bool DEBUG_BOUNDS = false;

// internal
static const int STAGE = 0;
// number of events remembered. 48 * 25ms outlives a particle (~0.94s).
static const int NUM_SLOTS = 48;
static const int BOX_MIN = 2;
static const int BOX_MAX = 3;
static const int SLOT_BASE = 4;
static const float TIME_WRAP = 64.0;

// hyper's default 16 colour palette in sRGB, in the order hyperpower's
// values(colors) produces them. particle i of a burst uses colour i % 16.
static const float3 PALETTE[16] = {
    float3(0x00, 0x00, 0x00) / 255.0, // black
    float3(0xC5, 0x1E, 0x14) / 255.0, // red
    float3(0x1D, 0xC1, 0x21) / 255.0, // green
    float3(0xC7, 0xC3, 0x29) / 255.0, // yellow
    float3(0x0A, 0x2F, 0xC4) / 255.0, // blue
    float3(0xC8, 0x39, 0xC5) / 255.0, // magenta
    float3(0x20, 0xC5, 0xC6) / 255.0, // cyan
    float3(0xC7, 0xC7, 0xC7) / 255.0, // white
    float3(0x68, 0x68, 0x68) / 255.0, // light black
    float3(0xFD, 0x6F, 0x6B) / 255.0, // light red
    float3(0x67, 0xF8, 0x6F) / 255.0, // light green
    float3(0xFF, 0xFA, 0x72) / 255.0, // light yellow
    float3(0x6A, 0x76, 0xFB) / 255.0, // light blue
    float3(0xFD, 0x7C, 0xFC) / 255.0, // light magenta
    float3(0x68, 0xFD, 0xFE) / 255.0, // light cyan
    float3(0xFF, 0xFF, 0xFF) / 255.0, // light white
};

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
texel_uv(int i, float2 vp) {
    return (float2(float(i), 0.0) + 0.5) / vp;
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

// number of hyperpower frames a particle stays visible (~56.4 by default).
static float
lifetime_frames() {
    return log(PARTICLE_ALPHA_MIN_THRESHOLD) / log(PARTICLE_ALPHA_FADEOUT);
}

// bounding box, in css pixels (y down), of every particle an event can have
// n frames after it spawned. padded to cover the 3x3 rects and their rounding.
static void
event_bounds(float2 origin, float n, out float2 lo, out float2 hi) {
    float drop = PARTICLE_GRAVITY * n * (n + 1.0) * 0.5;
    lo = origin + float2(PARTICLE_VELOCITY_RANGE_X.x, PARTICLE_VELOCITY_RANGE_Y.x) * n + float2(0.0, drop) - 2.0;
    hi = origin + float2(PARTICLE_VELOCITY_RANGE_X.y, PARTICLE_VELOCITY_RANGE_Y.y) * n + float2(0.0, drop) + 3.0;
}

static float2
css_to_uv(float2 css, float2 vp) {
    float2 uv = css * PIXEL_SCALE / vp;
    return float2(uv.x, 1.0 - uv.y);
}

// --- stage 0: record cursor moves into the ring buffer ---

struct Update {
    bool stale, spawn;
    int idx;
    float now, last_spawn, moved_at, lifetime;
};

static Update
begin_update(KittyTextures t, KittyCustomShaderData d, float2 vp) {
    float4 head = t.persist.Sample(texel_uv(0, vp));
    float4 tick = t.persist.Sample(texel_uv(1, vp));
    Update u;
    u.now = d.timestamp;
    u.lifetime = lifetime_frames() / FPS;

    // the group only runs while animating: if the last update is older than
    // a particle's lifetime, every stored slot is dead and may even look
    // alive again once its mod-64s timestamp wraps, so start afresh.
    float last_update = decode_time(tick.xy);
    u.stale = u.now - last_update > u.lifetime || last_update > u.now + 1.0;

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

// the new value of a slot this frame. y <= 0 marks an empty slot.
static float3
updated_slot(KittyTextures t, KittyCustomShaderData d, Update u, int slot, float2 vp) {
    if (u.spawn && slot == u.idx) {
        // hyperpower sprays from the cursor's top-left corner
        return float3(d.cursor_trail_edge.x, d.cursor_trail_edge.z, fract(u.moved_at / TIME_WRAP));
    }
    if (u.stale) return float3(0.0);
    float3 cur = t.persist.Sample(texel_uv(SLOT_BASE + slot, vp)).xyz;
    if (cur.y <= 0.0 || slot_age(u.now, cur.z) > u.lifetime) return float3(0.0);
    return cur;
}

static float4
update_state(KittyTextures t, KittyCustomShaderData d, int texel, float2 vp) {
    Update u = begin_update(t, d, vp);
    if (texel == 0) return float4(encode_time(u.last_spawn), float(u.idx) / 65535.0, 1.0);
    if (texel == 1) return float4(encode_time(u.now), 0.0, 1.0);
    if (texel >= SLOT_BASE) return float4(updated_slot(t, d, u, texel - SLOT_BASE, vp), 1.0);

    // union of the bounding boxes of all live events, in css pixels
    float2 lo = float2(1e9), hi = float2(-1e9);
    for (int slot = 0; slot < NUM_SLOTS; slot++) {
        float3 ev = updated_slot(t, d, u, slot, vp);
        if (ev.y <= 0.0) continue;
        float2 elo, ehi;
        event_bounds(float2(ev.x, 1.0 - ev.y) * vp / PIXEL_SCALE, slot_age(u.now, ev.z) * FPS, elo, ehi);
        lo = min(lo, elo);
        hi = max(hi, ehi);
    }
    // nothing alive: an empty box, min above max, so stage 2 skips every pixel
    if (lo.x > hi.x) return texel == BOX_MIN ? float4(1.0, 1.0, 0.0, 1.0) : float4(0.0, 0.0, 0.0, 1.0);
    // y flips going to UV, so css min y becomes UV max y. widen by a texel
    // either side to absorb the 16 bit quantisation.
    float2 uv_lo = css_to_uv(float2(lo.x, hi.y), vp) - 1.0 / vp;
    float2 uv_hi = css_to_uv(float2(hi.x, lo.y), vp) + 1.0 / vp;
    if (texel == BOX_MIN) return float4(saturate(uv_lo), 0.0, 1.0);
    return float4(saturate(uv_hi), 0.0, 1.0);
}

// --- stage 2: draw the particles ---

static float4
draw_particles(float4 color, KittyTextures t, KittyCustomShaderData d, float2 vp) {
    float2 box_lo = t.a.Sample(texel_uv(BOX_MIN, vp)).xy;
    float2 box_hi = t.a.Sample(texel_uv(BOX_MAX, vp)).xy;
    if (any(t.pos < box_lo) || any(t.pos > box_hi)) return color;
    if (DEBUG_BOUNDS) color.rgb = lerp(color.rgb, float3(0.0, 0.05, 0.2), 0.5);

    float4 head = t.a.Sample(texel_uv(0, vp));
    int idx = int(unorm16(head.z)) % NUM_SLOTS;
    float now = d.timestamp;
    float max_frames = lifetime_frames();

    // this pixel's position in hyperpower's css pixel space (origin top-left)
    float2 p = float2(t.pos.x, 1.0 - t.pos.y) * vp / PIXEL_SCALE;

    // composite front to back: newest event first, last particle first,
    // matching the canvas draw order of hyperpower. blending happens in sRGB
    // space like it does on a canvas.
    float3 acc = float3(0.0);
    float acc_a = 0.0;
    for (int k = 0; k < NUM_SLOTS; k++) {
        int slot = (idx - k + NUM_SLOTS) % NUM_SLOTS;
        float4 ev = t.a.Sample(texel_uv(SLOT_BASE + slot, vp));
        if (ev.y <= 0.0) break;
        float n = slot_age(now, ev.z) * FPS;
        if (n > max_frames) break;

        float2 origin = float2(ev.x, 1.0 - ev.y) * vp / PIXEL_SCALE;
        float2 lo, hi;
        event_bounds(origin, n, lo, hi);
        if (any(p < lo) || any(p > hi)) continue;

        float drop = PARTICLE_GRAVITY * n * (n + 1.0) * 0.5;
        float alpha = pow(PARTICLE_ALPHA_FADEOUT, n);
        uint seed = pcg(uint(unorm16(ev.z)) ^ pcg(uint(unorm16(ev.x)) ^ pcg(uint(unorm16(ev.y)))));
        int count = 5 + int(round(rand(seed) * 5.0));
        float2 vel[10];
        for (int i = 0; i < 10; i++) {
            vel[i] = float2(lerp(PARTICLE_VELOCITY_RANGE_X.x, PARTICLE_VELOCITY_RANGE_X.y, rand(seed)),
                            lerp(PARTICLE_VELOCITY_RANGE_Y.x, PARTICLE_VELOCITY_RANGE_Y.y, rand(seed)));
        }
        for (int i = count - 1; i >= 0; i--) {
            float2 q = origin + vel[i] * n + float2(0.0, drop);
            // canvas fillRect(round(x - 1), round(y - 1), 3, 3)
            float2 corner = round(q - 1.0);
            if (any(p < corner) || any(p >= corner + 3.0)) continue;
            float3 c = USE_CURSOR_COLOR ? to_srgb(d.cursor_color.rgb) : PALETTE[i % 16];
            acc += (1.0 - acc_a) * alpha * c;
            acc_a += (1.0 - acc_a) * alpha;
        }
    }
    if (acc_a <= 0.0) return color;
    float3 bg = to_srgb(color.rgb);
    return float4(to_linear(acc + (1.0 - acc_a) * bg), max(color.a, acc_a));
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    float2 vp = float2(d.viewport_size_pixels);
    if (STAGE == 2) return draw_particles(color, t, d, vp);

    // stages 0 and 1 render into a viewport anchored at the bottom-left, and
    // t.pos spans [0, 1] across it. kitty sizes it in whole pixels, truncating.
    float2 group_px = floor(t.viewport.zw * vp + 1e-3);
    int2 px = int2(floor(t.pos * group_px));
    if (px.y != 0 || px.x >= SLOT_BASE + NUM_SLOTS) return float4(0.0, 0.0, 0.0, 1.0);
    if (STAGE == 0) return update_state(t, d, px.x, vp);
    return float4(t.a.Sample(texel_uv(px.x, vp)).xyz, 1.0);
}
