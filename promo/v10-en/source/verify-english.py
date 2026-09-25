import sys, re, json, subprocess, ast
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'source'))
from timing import presentation_time
cjk=re.compile('[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]')
source=(ROOT/'source/render-film.py').read_text()
strings=[n.value for n in ast.walk(ast.parse(source)) if isinstance(n,ast.Constant) and isinstance(n.value,str)]
assert not any(cjk.search(s) for s in strings)
assert not cjk.search((ROOT/'output/EchoTerm-Promo-English-v10-46s.srt').read_text())
frames=[ROOT/f'previews/encoded-{presentation_time(s):05.2f}.png' for s in [7.75,9.7,11.7,17.8,20.5,23.9,29.5]]
paths=[ROOT/'assets/blocks-en.png']+frames
result=json.loads(subprocess.check_output([str(ROOT/'source/ocr-check'),*[str(p) for p in paths]]))
findings=[{'file':row['file'],'text':s} for row in result for s in row['recognized'] if cjk.search(s)]
proof={'language':'English','rendered_string_literals_checked':len(strings),'source_strings_cjk':False,'srt_cjk':False,'ocr_images_checked':len(paths),'ocr_cjk_findings':findings,'recognized':result}
(ROOT/'source/language-check.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in proof.items() if k!='recognized'},ensure_ascii=False,indent=2))
assert not findings, 'Review OCR findings before delivery'
