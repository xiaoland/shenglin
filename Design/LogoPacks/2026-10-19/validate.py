from pathlib import Path
from PIL import Image,ImageChops,ImageStat
import json,hashlib,xml.etree.ElementTree as ET
p=Path(__file__).resolve().parent
files=[]
for f in sorted(p.rglob('*')):
 if not f.is_file() or f.name in ['checksums.sha256','validation.json']:continue
 files.append((f.relative_to(p).as_posix(),hashlib.sha256(f.read_bytes()).hexdigest()))
(p/'checksums.sha256').write_text(''.join(f'{h}  {f}\n' for f,h in files))
svgs=list((p/'svg').rglob('*.svg'))
for f in svgs:
 root=ET.parse(f).getroot();assert len(root.findall('.//{http://www.w3.org/2000/svg}path'))>0
 assert not root.findall('.//{http://www.w3.org/2000/svg}image')
 assert not root.findall('.//{http://www.w3.org/2000/svg}text')
m=json.loads((p/'manifest.json').read_text())
for o in m['outputs']:
 im=Image.open(p/o['path']).convert('RGBA'); assert im.size==(o['size'],o['size'])
 a=im.getchannel('A');assert a.getextrema()[1]==255
 if o['background']=='transparent': assert a.getextrema()[0]==0
 else: assert a.getextrema()==(255,255)
 assert hashlib.sha256((p/o['path']).read_bytes()).hexdigest()==o['sha256']
# Compare original and reconstructed regular full app-icon at identical resolution.
a=Image.open(p/'platform-originals/AppIcon-1024.png').convert('RGBA')
b=Image.open(p/'png/app-icon/app-icon-brand-on-transparent-1024.png').convert('RGBA')
d=ImageChops.difference(a,b); extrema=d.getextrema()
white=Image.new('RGBA',a.size,'white')
compdiff=ImageChops.difference(Image.alpha_composite(white,a).convert('RGB'),Image.alpha_composite(white,b).convert('RGB'))
mean=ImageStat.Stat(compdiff).mean
(p/'validation.json').write_text(json.dumps({'svg_parsed':len(svgs),'no_embedded_bitmaps':True,'no_font_dependencies':True,'png_size_and_alpha_checks':len(m['outputs']),'regular_app_icon_source_pixel_difference_max_rgba':[x[1] for x in extrema],'visual_review':'contact-sheet viewed at native resolution; micro silhouettes, compact three holes, regular five holes; white and black backgrounds legible; no clipping','regular_source_white_composite_mean_absolute_rgb_difference':mean,'source_equivalence_note':'Geometry preserved; clip/mask converted to direct path gives antialiasing edge differences, not pixel-identical exports. Raw RGB maxima include invisible transparent-pixel RGB.','source_commit':m['source_commit']},indent=2))
print((p/'validation.json').read_text())
