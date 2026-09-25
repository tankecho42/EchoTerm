"""Hand-drawn lowercase bitmap lettering for the film's 'block.' moment.

Every stroke is exactly one occupied cell. All letters share one x-height,
baseline, grid pitch and square size. This does not sample an antialiased font.
"""
import numpy as np

PITCH = 6.0
SQUARE = 5.2
TOP_CENTER = 149.0
TRACKING = 2
GLYPHS = {
    'b': ('100000', '100000', '111110', '100001', '100001',
          '100001', '100001', '100001', '111110'),
    'l': ('10', '10', '10', '10', '10', '10', '10', '10', '11'),
    'o': ('000000', '000000', '011110', '100001', '100001',
          '100001', '100001', '100001', '011110'),
    'c': ('000000', '000000', '011111', '100000', '100000',
          '100000', '100000', '100000', '011111'),
    'k': ('10000', '10000', '10001', '10010', '10100',
          '11000', '10100', '10010', '10001'),
    '.': ('0', '0', '0', '0', '0', '0', '0', '0', '1'),
}

def word_grid(word='block.'):
    points=[];offset=0;letters=[]
    for i,char in enumerate(word):
        rows=GLYPHS[char];width=len(rows[0]);start=len(points)
        assert len(rows)==9 and all(len(row)==width for row in rows)
        for y,row in enumerate(rows):
            for x,cell in enumerate(row):
                if cell=='1':points.append((offset+x,y))
        letters.append(dict(letter=char,column=offset,width=width,
                            pixel_start=start,pixel_count=len(points)-start))
        gap=1 if i+1<len(word) and word[i+1]=='.' else TRACKING
        offset+=width+gap
    return np.asarray(points,float),letters

def layout(prefix,canvas_width):
    grid,letters=word_grid()
    _,xs=np.where(prefix[:,:,3]>128)
    left,right=float(xs.min()),float(xs.max()+1)
    word_width=grid[:,0].max()*PITCH+SQUARE
    gap=22.0
    total=right-left+gap+word_width
    ink_left=(canvas_width-total)/2
    prefix_x=ink_left-left
    first_center=ink_left+(right-left)+gap+SQUARE/2
    points=grid*PITCH+[first_center,TOP_CENTER]
    return prefix_x,points,letters
