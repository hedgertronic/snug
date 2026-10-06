"""Build a standalone visual review of frozen selection evaluation results."""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
directory = root / 'notes/evaluation'
labels = json.loads((directory / 'labels.json').read_text())
outcomes = json.loads((directory / 'outcomes.json').read_text())
for item in outcomes:
    item['image'] = '../real-web/' + Path(item['image']).name
payload = json.dumps({'labels': labels, 'outcomes': outcomes}).replace('<', '\\u003c')
html = '''<!doctype html><meta charset="utf-8"><title>Screenshot selection review</title>
<style>body{font:16px system-ui;margin:24px;background:#17191d;color:#eee}select,button{font:inherit;padding:8px}p{max-width:1000px}svg{width:100%;max-height:75vh;background:#222}#description{color:#bbb}.target{stroke:#20e36e}.selected{stroke:#ff4477}.best{stroke:#4caaff}</style>
<h1>Screenshot selection review</h1><p>Provisional targets from four development screenshots. Green: desired crop. Pink: default selection. Dashed blue: best available proposal. Yellow dot: cursor anchor. This is a review of cached results, not a live detector.</p>
<label>Target <select id="target"></select></label> <label>Detector <select id="mode"><option>geometry</option><option>vision</option></select></label>
<p id="description"></p><p id="metrics"></p><svg id="canvas" viewBox="0 0 2560 1600" role="img" aria-label="Screenshot with target and detector rectangles"></svg>
<script>const data=PAYLOAD;
const targets=document.querySelector('#target'), mode=document.querySelector('#mode');
for(const label of data.labels){const o=document.createElement('option');o.value=label.id;o.textContent=label.id;targets.append(o)}
const svg=document.querySelector('#canvas'), ns='http://www.w3.org/2000/svg';
function shape(tag,attrs){const e=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))e.setAttribute(k,v);svg.append(e);return e}
function box(bounds,cls,dash){if(!bounds)return;const [[x,y],[w,h]]=bounds;shape('rect',{x,y,width:w,height:h,fill:'none',class:cls,'stroke-width':5,'stroke-dasharray':dash||'none'})}
function render(){const r=data.outcomes.find(r=>r.id===targets.value&&r.detector===mode.value), l=data.labels.find(l=>l.id===targets.value);svg.replaceChildren();shape('image',{href:r.image,width:2560,height:1600});box(r.target,'target');box(r.bestCandidate?.bounds,'best','16 10');box(r.selected?.bounds,'selected');shape('circle',{cx:r.anchor[0],cy:r.anchor[1],r:9,fill:'yellow',stroke:'#000','stroke-width':2});document.querySelector('#description').textContent=l.expectation+' — '+l.ambiguity;document.querySelector('#metrics').textContent=`Default overlap: ${r.defaultIoU.toFixed(3)} · Best proposal: ${r.bestIoU.toFixed(3)} · Target proposal within 8px: ${r.proposalMatchesEdges} · Keyboard corrections: ${r.correctionsWithinTwo??'not reached within two'}`}
targets.onchange=mode.onchange=render;render();</script>'''.replace('PAYLOAD', payload)
(directory / 'review.html').write_text(html)
print(directory / 'review.html')
