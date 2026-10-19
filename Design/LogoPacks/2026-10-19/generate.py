#!/usr/bin/env python3
"""Rebuild with Python 3, Pillow and Inkscape. No upstream/network writes."""
from pathlib import Path
import xml.etree.ElementTree as ET
import subprocess, hashlib, json, concurrent.futures
from PIL import Image, ImageDraw
P=Path(__file__).resolve().parent
N={'s':'http://www.w3.org/2000/svg'}
root=ET.parse(P/'source/Design__AppIcon-iPad.svg').getroot()
body=root.find('s:path',N).get('d')
SHA='71baa5f5aa54a486484e4a302d181430afc48033'
SIZES=[16,24,32,48,64,128,256,512,1024]
def capsule(x,y,w,h):
 r=w/2
 return f'M{x+r},{y}A{r},{r} 0 0 1 {x+w},{y+r}V{y+h-r}A{r},{r} 0 0 1 {x+r},{y+h}A{r},{r} 0 0 1 {x},{y+h-r}V{y+r}A{r},{r} 0 0 1 {x+r},{y}Z'
def mark(opt):
 if opt=='micro': return body
 bars=[(739,806,20,48),(774,788,20,84),(809,766,20,128),(844,788,20,84),(879,806,20,48)] if opt=='regular' else [(752,793,32,74),(803,763,32,134),(854,793,32,74)]
 return body+' '+' '.join(capsule(*b) for b in bars)
def svg(kind,opt,color,bg):
 bgfill={'white':'#ffffff','black':'#000000','transparent':None}[bg]
 fill={'brand':'#065e6e','white':'#ffffff','black':'#000000'}[color]
 start='<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1254 1254">'
 if bgfill: start+=f'<path id="background" fill="{bgfill}" d="M0 0H1254V1254H0Z"/>'
 if kind=='mark':
  # Existing standalone footprint preserved; small geometry expands occupancy.
  t='translate(-87.78 -87.78) scale(1.14)' if opt=='micro' else ('translate(-37.62 -37.62) scale(1.06)' if opt=='compact' else '')
  return start+f'<path id="mark" transform="{t}" fill="{fill}" fill-rule="evenodd" d="{mark(opt)}"/></svg>'
 t='translate(122.4609375 122.4609375) scale(0.8046875)' if opt=='regular' else 'translate(78.375 78.375) scale(0.875)'
 tile='M235 0H1019Q1254 0 1254 235V1019Q1254 1254 1019 1254H235Q0 1254 0 1019V235Q0 0 235 0Z'
 # use arc corners to preserve original rect rx exactly
 tile='M235 0H1019A235 235 0 0 1 1254 235V1019A235 235 0 0 1 1019 1254H235A235 235 0 0 1 0 1019V235A235 235 0 0 1 235 0Z'
 return start+f'<g id="app-icon" transform="{t}"><path id="tile" fill="#065e6e" d="{tile}"/><path id="mark" fill="white" fill-rule="evenodd" d="{mark(opt)}"/></g></svg>'
combos=[('brand',b) for b in ['transparent','white','black']]+[('white',b) for b in ['transparent','black']]+[('black',b) for b in ['transparent','white']]
outputs=[]; jobs=[]
for kind in ['mark','app-icon']:
 for color,bg in (combos if kind=='mark' else [('brand',b) for b in ['transparent','white','black']]):
  for opt in ['micro','compact','regular']:
   f=P/'svg'/kind/f'{kind}-{color}-on-{bg}-{opt}.svg'; f.parent.mkdir(parents=True,exist_ok=True); f.write_text(svg(kind,opt,color,bg))
  for size in SIZES:
   opt='micro' if size<=24 else 'compact' if size<=48 else 'regular'
   src=P/'svg'/kind/f'{kind}-{color}-on-{bg}-{opt}.svg'
   dst=P/'png'/kind/f'{kind}-{color}-on-{bg}-{size}.png'; dst.parent.mkdir(parents=True,exist_ok=True)
   jobs.append((src,dst,size)); outputs.append({'path':str(dst.relative_to(P)),'size':size,'optical':opt,'kind':kind,'color':color,'background':bg})
def render(job):
 s,d,z=job
 subprocess.run(['inkscape',str(s),f'--export-filename={d}',f'--export-width={z}',f'--export-height={z}'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(render,jobs))
# Preserve original iPad full-bleed and Mac appicon independently, never replace logo mark with tile.
for name in ['AppIcon-iPad','AppIcon','MenuBarIcon']:
 d=P/'platform-originals';d.mkdir(exist_ok=True)
 s=P/'source'/f'Design__{name}.svg';(d/f'{name}.svg').write_bytes(s.read_bytes())
 for z in ([16,24,32,48] if name=='MenuBarIcon' else [128,256,512,1024]):render((s,d/f'{name}-{z}.png',z))
# Grid: larger representatives and native-size optical comparisons.
w,h=1120,1000; canvas=Image.new('RGB',(w,h),'#e4e7eb'); draw=ImageDraw.Draw(canvas)
draw.text((24,18),'SHENGLIN / EXISTING IDENTITY / LOGO PACKAGE',fill='#17212b')
reps=[('mark','brand','white'),('mark','white','black'),('mark','black','white'),('app-icon','brand','white'),('mark','brand','transparent'),('mark','white','transparent'),('mark','black','transparent'),('app-icon','brand','black')]
for i,(kind,c,bg) in enumerate(reps):
 x=20+(i%4)*275;y=55+(i//4)*290
 tile=Image.new('RGBA',(255,255),'#b7bdc5' if c=='white' else '#f8f9fa')
 if bg=='transparent':
  td=ImageDraw.Draw(tile)
  for yy in range(0,255,15):
   for xx in range(0,255,15):
    if (xx//15+yy//15)%2: td.rectangle((xx,yy,xx+14,yy+14),fill='#a4abb4' if c=='white' else '#dce0e4')
 im=Image.open(P/'png'/kind/f'{kind}-{c}-on-{bg}-256.png').convert('RGBA').resize((255,255))
 tile.alpha_composite(im); canvas.paste(tile.convert('RGB'),(x,y));draw.text((x,y+262),f'{kind} / {c} / {bg}',fill='#17212b')
draw.text((24,658),'OPTICAL SIZES / actual pixel sizes (micro 16-24, compact 32-48, regular 64+)',fill='#17212b')
for row,kind in enumerate(['mark','app-icon']):
 y=700+row*140;draw.text((24,y+20),kind,fill='#17212b');x=140
 for z in [16,24,32,48,64,128]:
  im=Image.open(P/'png'/kind/f'{kind}-brand-on-transparent-{z}.png').convert('RGBA');canvas.paste(im,(x,y),im);draw.text((x,y+130),str(z),fill='#17212b');x+=150
canvas.save(P/'contact-sheet.png')
for o in outputs:
 f=P/o['path']; im=Image.open(f);assert im.size==(o['size'],o['size']);o['sha256']=hashlib.sha256(f.read_bytes()).hexdigest()
 o['alpha_extrema']=im.convert('RGBA').getchannel('A').getextrema()
(P/'manifest.json').write_text(json.dumps({'source_commit':SHA,'outputs':outputs,'png_count':len(outputs),'svg_master_count':30,'platform_original_png_count':12},indent=2))
print('built',len(outputs),'PNG + 30 SVG masters + original platform assets')
