"""Localize labels in the existing capture, retaining its terminal output.

This is a localized plate for the product film, not a change to the application.
"""
import sys, subprocess, json
from pathlib import Path
import cv2, numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
original = np.asarray(Image.open(ROOT.parent/'stills/blocks.jpg').convert('RGB'))
labels = [
    ((13, 47, 54, 15), 'SESSIONS', 8, (142,147,159), (14,50)),
    ((47, 94, 103, 17), 'Auto · Chat', 8, (144,150,162), (48,98)),
    ((47, 116, 113, 20), 'Dev Notes', 11, (215,219,229), (48,121)),
    ((47, 135, 112, 17), 'Auto · Chat', 8, (144,150,162), (48,139)),
    ((47, 161, 117, 21), 'New session', 10, (148,157,172), (48,166)),
]
for y in [139,306,637]:
    labels += [((246,y,44,14),'Explain',8,(154,174,211),(247,y+2)),
               ((324,y,31,14),'Next',8,(154,174,211),(326,y+2))]
mask = np.zeros(original.shape[:2],np.uint8)
for (x,y,w,h), *_ in labels: mask[y:y+h,x:x+w] = 255
plate = cv2.inpaint(original,mask,4,cv2.INPAINT_TELEA)
for i,(_,string,size,color,(x,y)) in enumerate(labels):
    path = ROOT/f'assets/type/localized-{i}.png'
    subprocess.run([str(ROOT/'source/text-render'),string,str(size),
                    ''.join(f'{c:02x}' for c in color),'0','1','0',str(path)],check=True)
    im=Image.open(path).convert('RGBA')
    box=im.getchannel('A').getbbox();im=np.asarray(im.crop(box))
    h,w=im.shape[:2];alpha=im[:,:,3:4]/255.
    plate[y:y+h,x:x+w]=np.uint8(plate[y:y+h,x:x+w]*(1-alpha)+im[:,:,:3]*alpha)
Image.fromarray(plate).save(ROOT/'assets/blocks-en.png')
(ROOT/'source/localized-labels.json').write_text(json.dumps(
    [dict(text=s,rect=r,position=p) for r,s,_,_,p in labels],indent=2))
print(ROOT/'assets/blocks-en.png')
