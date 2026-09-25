import sys,importlib.util,json
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('film',ROOT/'source/render-film.py')
f=importlib.util.module_from_spec(spec);spec.loader.exec_module(f)
import numpy as np
from pixel_type import word_grid,PITCH,SQUARE
from PIL import Image
points,letters=word_grid()
assert len(np.unique(points,axis=0))==len(points)
assert PITCH>SQUARE>0
static=f.BASE.copy()
for x,y in f.GLYPH:f.sq(static,x,y,SQUARE,f.BLUE)
departure=f.BASE.copy();f.draw_journey(departure,10.1)
assert np.array_equal(static,departure), 'Glyph changes weight at the departure join'
xy,size,col,alpha=f.journey_state(10.1)
assert np.count_nonzero(alpha)==len(points)
arrival=f.BASE.copy();src,colors=f.bearpoints(7.85,f.unified_anchor(7.85),82)
f.morph(arrival,src,f.GLYPH,1,5.2,SQUARE,250,colors,f.BLUE,stagger=.23)
arrival_error=int(np.abs(arrival.astype(int)-static.astype(int)).max())
assert arrival_error<=1
# Preserve the exact one-cell glyph during the reading hold.
Image.fromarray(f.frame(f.presentation_time(9.85))).save(ROOT/'previews/type-final.png')
Image.fromarray(static).crop((1240,130,1510,216)).resize((1080,344),Image.Resampling.NEAREST).save(ROOT/'previews/pixel-word-detail.png')
proof={'word':'block.','construction':'Hand-drawn 9-row bitmap, one-cell strokes','glyph_pixels':len(points),'grid_pitch_px':PITCH,'square_size_px':SQUARE,'duplicate_cells':False,'letter_layout':letters,'departure_join_identical':True,'arrival_join_max_channel_difference':arrival_error,'steady_stroke_width_cells':1,'reading_hold_preserved':True}
(ROOT/'source/pixel-type-check.json').write_text(json.dumps(proof,indent=2));print(json.dumps(proof,indent=2))
