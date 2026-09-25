"""Editorial breathing room: preserve travel speed, ease into readable poses.

source_time is the existing 30-second choreography. presentation_time is the
46-second finished film, including a five-second opening. The strictly monotonic C2 map adds time inside formed
poses, not across the whole film; it never stops or reverses the animation.
Sound design and subtitles use exactly the same map as the pictures.
"""
import numpy as np

SOURCE_DURATION = 30.0
LEAD_IN = 5.0
FPS = 60
# label, source interval, extra seconds. Intervals fall after shape formation.
HOLDS = [
    ('block_title',       9.62, 10.08, 1.65),
    ('question_echo',    12.10, 12.40, 1.15),
    ('selected_block',   17.68, 17.83, 1.25),
    ('port_highlight',   18.57, 18.64, 1.65),
    ('returned_answer', 20.605,20.648, 1.70),
    ('glass_arrival',    22.43, 22.50, 0.90),
    ('three_themes',    24.995,25.045, 1.75),
    ('wordmark',         28.80, 29.50, 0.95),
]
DURATION = LEAD_IN + SOURCE_DURATION + sum(h[3] for h in HOLDS)
FRAME_COUNT = round(DURATION * FPS)

def presentation_time(source):
    t = np.asarray(source, dtype=float)
    out = t.copy() + LEAD_IN
    for _, lo, hi, extra in HOLDS:
        u = np.clip((t-lo)/(hi-lo), 0, 1)
        out = out + extra * u**3 * (10 - 15*u + 6*u*u)
    return float(out) if out.ndim == 0 else out

def source_time(presentation):
    # Bisection avoids numerical timing steps at very narrow held poses.
    t = float(np.clip(presentation, LEAD_IN, DURATION))
    lo, hi = 0., SOURCE_DURATION
    for _ in range(36):
        mid = (lo+hi)*.5
        if presentation_time(mid) < t:
            lo = mid
        else:
            hi = mid
    return (lo+hi)*.5

def hold_report():
    return [dict(name=name, source_start=lo, source_end=hi,
                 start=round(presentation_time(lo), 4),
                 end=round(presentation_time(hi), 4),
                 duration=round(hi-lo+extra, 4))
            for name, lo, hi, extra in HOLDS]
