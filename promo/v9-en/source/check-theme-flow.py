import sys, importlib.util, json
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location('film',ROOT/'source/render-film.py')
film=importlib.util.module_from_spec(spec);spec.loader.exec_module(film)
import numpy as np
from timing import *
previous=None;motion=[]
start=round(presentation_time(22.30)*60);end=round(presentation_time(25.05)*60)
for n in range(start,end+1):
 s=source_time(n/60);xy,size,col,alpha=film.theme_journey(s)
 assert len(xy)==168 and np.isfinite(xy).all() and np.isfinite(col).all()
 if previous is not None:motion.append(float(np.median(np.linalg.norm(xy-previous,axis=1))))
 previous=xy
joins=[]
for st in [20.65,22.30,25.05]:
 before=film.journey_state(st-1e-5);after=film.journey_state(st+1e-5)
 delta=float(np.max(np.linalg.norm(before[0]-after[0],axis=1)))
 assert delta<.10
 joins.append({'source_second':st,'max_position_delta_px_at_20us':delta})
assert min(motion)>.25
proof={'duration':DURATION,'frames':FRAME_COUNT,'flow_span':FLOW_SPANS,'removed_holds':['glass_arrival','three_themes'],'ribbon_particles':168,'theme_source_interval':[22.3,25.05],'frames_checked':end-start+1,'minimum_median_pixel_motion_px_per_frame':min(motion),'maximum_median_pixel_motion_px_per_frame':max(motion),'joins':joins,'intermediate_theme_avatar':False,'theme_clock':'presentation seconds, continuous closed curve'}
(ROOT/'source/theme-flow-check.json').write_text(json.dumps(proof,indent=2))
print(json.dumps(proof,indent=2))
