'use strict';
// Snug site: the overlay demo and the feature vignettes. Coordinates in the demo are the mock screen's own
// (unscaled) CSS pixels; the screen element is scaled to fit, so every client rect is divided by `scale`.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const R = Math.round;
  const clamp = (v, a, b) => Math.min(Math.max(v, a), b);

  /* ---------- toast ---------- */
  const toastEl = document.querySelector('.toast');
  const thumb = toastEl.querySelector('.t-thumb');
  let toastT = 0;
  function toast(title, detail = '', { aspect = 1, swatch = '' } = {}) {
    toastEl.querySelector('.t-title').textContent = title;
    toastEl.querySelector('.t-detail').textContent = detail;
    thumb.classList.toggle('sw', !!swatch);
    thumb.firstElementChild.style.background = swatch;
    thumb.firstElementChild.style.width = `${Math.max(4, aspect >= 1 ? 40 : 40 * aspect)}px`;
    thumb.firstElementChild.style.height = `${Math.max(4, aspect >= 1 ? 40 / aspect : 40)}px`;
    toastEl.classList.add('show');
    clearTimeout(toastT);
    toastT = setTimeout(() => toastEl.classList.remove('show'), 4000);
  }
  toastEl.addEventListener('pointerenter', () => clearTimeout(toastT));
  toastEl.addEventListener('pointerleave', () => { toastT = setTimeout(() => toastEl.classList.remove('show'), 2000); });

  /* ---------- colors ---------- */
  const FORMATS = ['HEX', 'RGB', 'HSL', 'Swift'];
  let fmtI = 0;
  function colorText([r, g, b], f = FORMATS[fmtI]) {
    if (f === 'HEX') return '#' + [r, g, b].map(v => v.toString(16).padStart(2, '0')).join('').toUpperCase();
    if (f === 'RGB') return `rgb(${r}, ${g}, ${b})`;
    if (f === 'Swift') return `Color(red: ${(r / 255).toFixed(3)}, green: ${(g / 255).toFixed(3)}, blue: ${(b / 255).toFixed(3)})`;
    const [x, y, z] = [r / 255, g / 255, b / 255], max = Math.max(x, y, z), min = Math.min(x, y, z), l = (max + min) / 2, d = max - min;
    const s = d ? d / (1 - Math.abs(2 * l - 1)) : 0;
    const h = !d ? 0 : max === x ? ((y - z) / d) % 6 : max === y ? (z - x) / d + 2 : (x - y) / d + 4;
    return `hsl(${R((h * 60 + 360) % 360)}, ${R(s * 100)}%, ${R(l * 100)}%)`;
  }
  const hex = c => colorText(c, 'HEX');

  /* ---------- keys go to the hovered interactive block, then the focused one ---------- */
  const keyed = [];
  document.addEventListener('keydown', e => {
    if (e.ctrlKey && e.shiftKey && e.code === 'Space') { e.preventDefault(); shortcut(); return; }
    if (e.ctrlKey) return;
    const hovered = keyed.filter(([el]) => el.matches(':hover')), focused = keyed.filter(([el]) => el.contains(document.activeElement));
    for (const [, fn] of [...new Set([...hovered, ...focused])]) if (fn(e)) { e.preventDefault(); return; }
  });

  /* =====================================================================================
     The overlay demo
     ===================================================================================== */
  const stage = document.querySelector('.stage');
  const screen = stage.querySelector('.screen');
  const scene = screen.querySelector('.scene');
  const ov = screen.querySelector('.ov');
  const [hl, dimall, hintUp, hintDown, framep, ghost, selEl, flashEl, rulerTop, rulerLeft, cross, sizeChip, cornerChip,
    strip, cluster, loupe, readout, bar] = ['.hl', '.dimall', '.hint.up', '.hint.down', '.framep', '.ghost', '.sel', '.flash',
    '.ruler.top', '.ruler.left', '.cross', '.chip.size', '.chip.corner', '.strip', '.chip.cluster', '.loupe', '.chip.readout',
    '.bar'].map(s => ov.querySelector(s));
  const lz = loupe.querySelector('.lz');
  const statusEl = document.querySelector('.demo-status');
  const legend = document.querySelector('.legend');
  for (const b of ov.querySelectorAll('button')) b.tabIndex = -1;

  const on = { s: true, l: false, r: false, x: false, o: false, m: false };
  const NAMES = { s: 'Snap', l: 'Loupe', r: 'Rulers', x: 'Crosshair', o: 'Rounded corners', m: 'Frame' };
  let W = 1000, H = 625, scale = 1;
  let open = true, mode = 'capture', meta = false;
  let target = scene.querySelector('.tbl');   // an element, 'desk' (the wallpaper), or the screen itself
  let hold = null, path = [], prevWF = null;  // a key-picked target holds until the pointer leaves it
  let sel = null, drag = null, grab = null, snapT = 0, glideT = 0;
  let ptr = null, inStage = false;

  const say = text => { statusEl.textContent = text; };
  const inside = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
  const near = (a, b, t) => Math.abs(a.x - b.x) <= t && Math.abs(a.y - b.y) <= t &&
    Math.abs(a.x + a.w - b.x - b.w) <= t && Math.abs(a.y + a.h - b.y - b.h) <= t;
  const size = r => `${R(r.w)} x ${R(r.h)}`;

  function box(el) {
    if (el === screen) return { x: 0, y: 0, w: W, h: H };
    const s = screen.getBoundingClientRect(), r = el.getBoundingClientRect();
    const x = Math.max(0, (r.left - s.left) / scale), y = Math.max(0, (r.top - s.top) / scale);
    return { x, y, w: Math.min(W, (r.right - s.left) / scale) - x, h: Math.min(H, (r.bottom - s.top) / scale) - y };
  }
  const toBase = e => {
    const s = screen.getBoundingClientRect();
    return { x: R((e.clientX - s.left) / scale), y: R((e.clientY - s.top) / scale) };
  };
  // The element under a point: the screen at its outer edge, 'desk' on the wallpaper, undefined over the chrome.
  function hitAt(p) {
    if (p.x < 2 || p.y < 2 || p.x > W - 2 || p.y > H - 2) return screen;
    const s = screen.getBoundingClientRect();
    const el = document.elementFromPoint(s.left + p.x * scale, s.top + p.y * scale);
    if (!el || !screen.contains(el) || ov.contains(el)) return undefined;
    const m = el.closest('[data-n]');
    return m === screen ? 'desk' : m;
  }
  const kids = p => [...(p === screen ? scene : p).querySelectorAll('[data-n]')]
    .filter(e => e.parentElement.closest('[data-n]') === p && e.getClientRects().length);
  function peers(el) {
    const list = kids(el.parentElement.closest('[data-n]')).map(e => [e, box(e)]);
    list.sort(([, a], [, b]) => Math.abs(a.y + a.h / 2 - b.y - b.h / 2) < Math.min(a.h, b.h) / 2 ? a.x - b.x : a.y - b.y);
    return list.map(([e]) => e);
  }
  const match = r => [...scene.querySelectorAll('[data-n]')].filter(e => e.getClientRects().length && near(box(e), r, 4)).pop() || null;

  // What Return copies now.
  function current() {
    if (sel) return { el: sel.el, r: sel, name: sel.el ? sel.el.dataset.n : 'Area' };
    if (target instanceof Element) return { el: target, r: box(target), name: target.dataset.n };
    return { el: screen, r: box(screen), name: 'Full screen' };
  }

  function hover() {
    if (!open || mode !== 'capture' || sel || drag || grab || !ptr) return;
    if (!strip.hidden) {
      const b = box(strip);
      if (inside({ x: b.x, y: b.y - 10, w: b.w, h: b.h + 10 }, ptr)) return;
    }
    if (hold) {
      const still = Math.hypot(ptr.x - hold.x, ptr.y - hold.y) < 30;
      const within = target instanceof Element && target !== screen && inside(box(target), ptr) && inside(box(target), hold);
      if (still || within) return;
      hold = null;
    }
    const t = hitAt(ptr);
    if (t !== undefined && t !== target) { target = t; path = []; prevWF = null; }
  }

  function glide() {
    if (reduce.matches) return;
    ov.classList.add('glide');
    clearTimeout(glideT);
    glideT = setTimeout(() => ov.classList.remove('glide'), 120);
  }
  function beep() {
    sizeChip.classList.remove('shake');
    void sizeChip.offsetWidth;
    sizeChip.classList.add('shake');
    say('Nothing further that way.');
  }

  function walk(k) {
    if (!(target instanceof Element)) return beep();
    let next = null;
    if (k === 'ArrowUp') {
      if (target !== screen) { next = target.parentElement.closest('[data-n]'); path.push(target); }
    } else if (k === 'ArrowDown') {
      next = path.pop() || (ptr && kids(target).find(e => inside(box(e), ptr))) || null;
    } else if (target !== screen) {
      const list = peers(target);
      if (list.length > 1) next = list[(list.indexOf(target) + (k === 'ArrowRight' ? 1 : list.length - 1)) % list.length];
      path = [];
    }
    if (!next) return beep();
    target = next;
    hold = { ...(ptr || { x: -99, y: -99 }) };
    glide();
    say(`${target.dataset.n}, ${size(box(target))}`);
  }

  function pick(k) {
    sel = null;
    let t = k === 'f' ? screen : target instanceof Element && target !== screen ? target : ptr && hitAt(ptr);
    if (k === 'w') t = t instanceof Element ? t.closest('.win') : null;
    if (!t) return beep();
    if (t === target && prevWF) { target = prevWF; prevWF = null; } else { prevWF = target; target = t; }
    hold = { ...(ptr || { x: -99, y: -99 }) };
    glide();
    say(target instanceof Element ? `${target.dataset.n}, ${size(box(target))}` : 'Back to the hover.');
  }

  function nudge(k, shift, alt) {
    const d = shift ? 10 : 1;
    const dx = k === 'ArrowLeft' ? -1 : k === 'ArrowRight' ? 1 : 0, dy = k === 'ArrowUp' ? -1 : k === 'ArrowDown' ? 1 : 0;
    if (alt) {  // grow the side facing the arrow
      const x2 = Math.min(W, sel.x + sel.w + (dx > 0 ? d : 0)), y2 = Math.min(H, sel.y + sel.h + (dy > 0 ? d : 0));
      sel.x = Math.max(0, sel.x - (dx < 0 ? d : 0));
      sel.y = Math.max(0, sel.y - (dy < 0 ? d : 0));
      sel.w = x2 - sel.x;
      sel.h = y2 - sel.y;
    } else {
      sel.x = clamp(sel.x + dx * d, 0, W - sel.w);
      sel.y = clamp(sel.y + dy * d, 0, H - sel.h);
    }
    sel.snapped = false;
    sel.el = match(sel);
    say(`${alt ? 'Grew' : 'Moved'} the area: ${size(sel)} at ${R(sel.x)}, ${R(sel.y)}`);
  }

  const CORNERS = ['Top left', 'Top right', 'Bottom right', 'Bottom left'];
  function corner(back) {
    sel.focus = sel.focus < 0 ? (back ? 3 : 0) : (sel.focus + (back ? 3 : 1)) % 4;
    say(`${CORNERS[sel.focus]} corner, radius ${sel.r[sel.focus]}`);
  }
  function radius(k, shift) {
    const d = (k === ']' ? 1 : -1) * (shift ? 4 : 1), max = Math.floor(Math.min(sel.w, sel.h) / 2);
    for (const i of sel.focus < 0 ? [0, 1, 2, 3] : [sel.focus]) sel.r[i] = clamp(sel.r[i] + d, 0, max);
    say(`${sel.focus < 0 ? 'All corners' : CORNERS[sel.focus]}: radius ${sel.focus < 0 ? sel.r[0] : sel.r[sel.focus]}`);
  }

  // Snap: each edge of a drawn area moves to the nearest edge within 10 px of an element beside it.
  const edges = () => [box(screen), ...[...scene.querySelectorAll('[data-n]')].filter(el => el.getClientRects().length).map(box)];
  function snapRect(r, boxes) {
    const to = (v, list) => {
      let best = v, d = 10.5;
      for (const c of list) if (Math.abs(c - v) < d) { d = Math.abs(c - v); best = c; }
      return best;
    };
    const xs = boxes.filter(b => b.y < r.y + r.h && b.y + b.h > r.y).flatMap(b => [b.x, b.x + b.w]);
    const ys = boxes.filter(b => b.x < r.x + r.w && b.x + b.w > r.x).flatMap(b => [b.y, b.y + b.h]);
    const x1 = to(r.x, xs), y1 = to(r.y, ys), x2 = to(r.x + r.w, xs), y2 = to(r.y + r.h, ys);
    return { x: x1, y: y1, w: Math.max(4, x2 - x1), h: Math.max(4, y2 - y1) };
  }

  function flash(r) {
    place(flashEl, r);
    flashEl.classList.remove('go');
    void flashEl.offsetWidth;
    flashEl.classList.add('go');
  }

  function copy(agent) {
    const { el, r, name } = current();
    flash(r);
    if (agent) {
      const id = handoff(el, r, name);
      toast('Copied for agent', id, { aspect: r.w / r.h });
      say(`Copied ${name} for an agent as capture ${id}. The panel in Agent handoff below shows what your agent gets.`);
    } else {
      const rad = sel ? Math.max(...sel.r) : +(el.dataset.r || 0);
      const style = [on.o && rad && `rounded r ${rad}`, on.m && 'framed'].filter(Boolean);
      toast('Copied', [name, size(r), ...style].join(', '), { aspect: r.w / r.h });
      say(`Copied ${name}, ${size(r)}.`);
    }
    setTimeout(closeOverlay, reduce.matches ? 0 : 260);
  }
  function save() {
    const { r, name } = current();
    flash(r);
    toast('Saved', `${name}, ${size(r)}, PNG`, { aspect: r.w / r.h });
    say(`Saved ${name} as a PNG.`);
    setTimeout(closeOverlay, reduce.matches ? 0 : 260);
  }
  function copyText() {
    const s = getSelection();
    if (s.isCollapsed || !scene.contains(s.anchorNode)) return beep();
    const n = s.toString().split('\n').filter(l => l.trim()).length;
    toast('Copied', `${n} line${n === 1 ? '' : 's'} of text`);
    say(`Copied ${n} line${n === 1 ? '' : 's'} of text.`);
    s.removeAllRanges();
    closeOverlay();
  }
  function colorAt(p) {
    const s = screen.getBoundingClientRect();
    for (let el = document.elementFromPoint(s.left + p.x * scale, s.top + p.y * scale); el && el !== document.body; el = el.parentElement) {
      const cs = getComputedStyle(el);
      const v = el instanceof SVGElement && !(el instanceof SVGSVGElement) && cs.fill !== 'none' ? cs.fill : cs.backgroundColor;
      const m = v.match(/[\d.]+/g);
      if (m && (m.length < 4 || +m[3] > 0)) return m.slice(0, 3).map(n => R(+n));
    }
    return [0, 0, 0];
  }
  function copyColor() {
    const c = colorAt(ptr || { x: W / 2, y: H / 2 });
    toast(`Copied ${colorText(c)}`, `${FORMATS[fmtI]} color`, { swatch: hex(c) });
    say(`Copied the color ${colorText(c)}.`);
  }

  function closeOverlay() {
    open = false; sel = null; drag = null; grab = null; mode = 'capture'; hold = null;
    getSelection().removeAllRanges();
    render();
  }
  function openOverlay() {
    open = true;
    hover();
    render();
    say('Overlay open. Point at anything.');
  }

  // Every key the demo knows. Returns whether it acted.
  function act(k, e = {}) {
    if (!open) return false;
    if (k === 'Escape') {
      const ts = getSelection();
      if (drag || grab) { drag = null; grab = null; }
      else if (sel && sel.focus >= 0) { sel.focus = -1; say('All corners.'); }
      else if (sel) { sel = null; hover(); say('Back to the hover.'); }
      else if (mode === 'text' && !ts.isCollapsed && scene.contains(ts.anchorNode)) ts.removeAllRanges();
      else { closeOverlay(); say('Closed. The clipboard is untouched.'); return true; }
    } else if (k === 'a' || k === 't') {
      mode = k === 'a' ? 'capture' : 'text';
      sel = null; drag = null;
      if (mode === 'capture') { getSelection().removeAllRanges(); hover(); }
      say(mode === 'text' ? 'Text mode: drag across any text, then press Return.' : 'Capture mode.');
    } else if (k === 'Enter') {
      if (mode === 'text') copyText(); else copy(!!e.metaKey);
      return true;
    } else if (k === 'c') copyColor();
    else if (k === 'C') { fmtI = (fmtI + 1) % FORMATS.length; syncFormat(); say(`Color format: ${FORMATS[fmtI]}`); }
    else if (k === 'l' || k === 'r' || k === 'x') {
      on[k] = !on[k];
      if (k === 'l') lz.replaceChildren(...on.l ? [scene.cloneNode(true)] : []);
      say(`${NAMES[k]} ${on[k] ? 'on' : 'off'}.`);
    } else if (mode === 'text') {
      if (k !== 'f') return false;
      getSelection().selectAllChildren(scene);
    } else if (k.startsWith('Arrow')) { if (sel) nudge(k, e.shiftKey, e.altKey); else walk(k); }
    else if (k === 'Tab' && sel) corner(e.shiftKey);
    else if ((k === '[' || k === ']') && sel) radius(k, e.shiftKey);
    else if (k === 'f' || k === 'w') pick(k);
    else if (k === 's' && e.metaKey) { save(); return true; }
    else if (k === 's' || k === 'o' || k === 'm') { on[k] = !on[k]; say(`${NAMES[k]} ${on[k] ? 'on' : 'off'}.`); }
    else return false;
    render();
    return true;
  }

  // The keycast chip names the chord just pressed, inside the demo, where the eye is.
  const keycast = ov.querySelector('.keycast');
  const GLYPH = { Meta: '\u2318', Alt: '\u2325', Shift: '\u21E7', Enter: '\u21A9', Escape: 'esc', Tab: 'tab', ArrowUp: '\u2191',
    ArrowDown: '\u2193', ArrowLeft: '\u2190', ArrowRight: '\u2192', C: 'C' };
  let castT = 0;
  function light(keys) {
    const key = keys[0], mods = ['Meta', 'Alt', 'Shift'].filter(m => keys.includes(m) && m !== key);
    if (key && !['Meta', 'Alt', 'Shift', 'arrows'].includes(key)) {
      keycast.innerHTML = [...mods, key].map(k => `<span class="kc">${GLYPH[k] || k.toUpperCase()}</span>`).join('');
      keycast.hidden = false;
      keycast.classList.remove('out');
      clearTimeout(castT);
      castT = setTimeout(() => { if (reduce.matches) keycast.hidden = true; else keycast.classList.add('out'); }, 700);
    }
    for (const b of legend.querySelectorAll('.key')) {
      if (!keys.includes(b.dataset.key)) continue;
      b.classList.add('on');
      setTimeout(() => b.classList.remove('on'), 150);
    }
  }

  keyed.push([stage, e => {
    if (e.key === 'Meta') { meta = true; render(); return false; }
    let k = e.key;
    if (e.metaKey && k !== 'Enter' && k.toLowerCase() !== 's') return false;
    if (k === '{') k = '[';
    if (k === '}') k = ']';
    if (k.length === 1 && !(k === 'C' && e.shiftKey)) k = k.toLowerCase();
    const done = act(k, e);
    if (done) light([k, e.metaKey && 'Meta', e.altKey && 'Alt', e.shiftKey && 'Shift', k.startsWith('Arrow') && sel && 'arrows']);
    return done;
  }]);
  document.addEventListener('keyup', e => { if (e.key === 'Meta' && meta) { meta = false; render(); } });
  addEventListener('blur', () => { if (meta) { meta = false; render(); } });

  /* ---------- pointer ---------- */
  screen.addEventListener('pointermove', e => {
    ptr = toBase(e);
    inStage = true;
    if (grab) dragMove(e); else hover();
    render();
  });
  screen.addEventListener('pointerleave', () => { inStage = false; render(); });
  screen.addEventListener('pointerdown', e => {
    if (e.button !== 0 || e.target.closest('button')) return;
    ptr = toBase(e);
    if (!open) { openOverlay(); return; }
    if (mode === 'text') return;
    e.preventDefault();
    stage.focus({ preventScroll: true });
    const h = e.target.closest('.h');
    const kind = e.pointerType === 'touch' ? 'tap' : h ? h.dataset.h : sel && inside(sel, ptr) ? 'move' : 'new';
    grab = { kind, start: ptr, orig: sel && { ...sel }, moved: false, hadSel: !!sel, edges: kind === 'new' && edges() };
    if (kind !== 'tap') screen.setPointerCapture(e.pointerId);
  });
  function dragMove(e) {
    const dx = ptr.x - grab.start.x, dy = ptr.y - grab.start.y;
    if (!grab.moved && Math.hypot(dx, dy) < 4) return;
    grab.moved = true;
    if (grab.kind === 'tap') return;
    if (grab.kind === 'new') {
      sel = null;
      const rect = { x: Math.min(grab.start.x, ptr.x), y: Math.min(grab.start.y, ptr.y), w: Math.abs(dx), h: Math.abs(dy) };
      const keep = !e.altKey && drag && drag.snap && near(snapRect(rect, grab.edges), drag.snap, 0);
      drag = { rect, snap: keep ? drag.snap : null };
      clearTimeout(snapT);
      // Pause to snap: the preview shows after a short rest.
      if (!keep && on.s && !e.altKey) {
        snapT = setTimeout(() => {
          if (!drag || !grab) return;
          const s = snapRect(drag.rect, grab.edges);
          drag.snap = near(s, drag.rect, .5) ? null : s;
          render();
        }, 80);
      }
    } else if (grab.kind === 'move') {
      sel.x = clamp(grab.orig.x + dx, 0, W - sel.w);
      sel.y = clamp(grab.orig.y + dy, 0, H - sel.h);
    } else {
      const o = grab.orig, k = grab.kind;
      let x1 = o.x, y1 = o.y, x2 = o.x + o.w, y2 = o.y + o.h;
      if (k.includes('w')) x1 = clamp(o.x + dx, 0, x2 - 4);
      if (k.includes('e')) x2 = clamp(o.x + o.w + dx, x1 + 4, W);
      if (k.includes('n')) y1 = clamp(o.y + dy, 0, y2 - 4);
      if (k.includes('s')) y2 = clamp(o.y + o.h + dy, y1 + 4, H);
      Object.assign(sel, { x: x1, y: y1, w: x2 - x1, h: y2 - y1, snapped: false });
      sel.el = match(sel);
    }
  }
  screen.addEventListener('pointerup', e => {
    if (!grab) return;
    const g = grab;
    grab = null;
    clearTimeout(snapT);
    if (g.kind === 'tap') {
      if (!g.moved) tap();
    } else if (g.kind === 'new') {
      if (drag) {
        const r = drag.snap && !e.altKey ? drag.snap : drag.rect;
        sel = { x: r.x, y: r.y, w: Math.max(4, r.w), h: Math.max(4, r.h), snapped: r === drag.snap, focus: -1 };
        sel.el = match(sel);
        sel.r = Array(4).fill(sel.el ? +(sel.el.dataset.r || 0) : 0);
        drag = null;
        say(`Area ${size(sel)}, ${sel.snapped ? 'snapped' : 'exact'}. Return copies; arrows move it; Tab focuses a corner.`);
      } else if (g.hadSel) { sel = null; hover(); }
      else copy(false);
    } else if (g.kind === 'move' && !g.moved) copy(false);
    render();
  });
  screen.addEventListener('pointercancel', () => { grab = null; drag = null; render(); });
  // Touch: a tap highlights, a second tap on the same element copies it.
  function tap() {
    const t = hitAt(ptr);
    if (t === undefined) return;
    if (t === target) return copy(false);
    target = t; path = []; hold = { ...ptr };
    say(t instanceof Element ? `${t.dataset.n}, ${size(box(t))}. Tap again to copy.` : 'The desktop. Tap again to copy the full screen.');
  }

  bar.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    act(b.dataset.key);
    light([b.dataset.key]);
    stage.focus({ preventScroll: true });
  });
  strip.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b) return;
    act(b.dataset.key, { metaKey: meta || b.dataset.mods === 'meta' });
    stage.focus({ preventScroll: true });
  });
  legend.addEventListener('click', e => {
    const b = e.target.closest('button.key');
    if (!b) return;
    const k = b.dataset.for || b.dataset.key, mods = b.dataset.mods || '';
    if (!open) openOverlay();
    act(k, { metaKey: mods.includes('meta'), altKey: mods.includes('alt'), shiftKey: mods.includes('shift') });
    light([k, b.dataset.key, mods.includes('meta') && 'Meta']);
    stage.focus({ preventScroll: true });
  });

  // Control-Shift-Space works anywhere on the page, as it does on the Mac.
  function shortcut() {
    if (recState === 'rec') return stopRec();
    const r = stage.getBoundingClientRect();
    stage.focus({ preventScroll: true });
    if (r.bottom < 0 || r.top > innerHeight) stage.scrollIntoView({ block: 'center', behavior: reduce.matches ? 'auto' : 'smooth' });
    if (!open) openOverlay();
  }

  /* ---------- drawing ---------- */
  function place(el, r) {
    el.hidden = !r;
    if (r) Object.assign(el.style, { left: `${r.x}px`, top: `${r.y}px`, width: `${r.w}px`, height: `${r.h}px` });
  }
  function at(el, x, y) {
    el.hidden = false;
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
  }
  const tag = (lit, text) => `<span class="tag${lit ? ' lit' : ''}">${text}</span>`;

  function render() {
    screen.dataset.mode = open ? mode : 'closed';
    ov.classList.toggle('cmd', meta);
    for (const b of bar.querySelectorAll('button')) {
      b.classList.toggle('cur', b.dataset.mode === mode);
      if (b.dataset.t) b.classList.toggle('lit', on[b.dataset.key]);
    }
    if (!open) return;
    const cap = mode === 'capture';
    const t = cap && !sel && !drag && target instanceof Element ? target : null;
    const tb = t && box(t);
    const r = !cap ? null : drag ? drag.snap || drag.rect : sel || tb;

    dimall.hidden = !(cap && !sel && !drag && target === 'desk');
    place(hl, tb);
    if (t) { hl.classList.toggle('full', t === screen); hl.style.borderRadius = `${t.dataset.r || 0}px`; }

    // Faint outlines show what Up and Down would pick.
    const up = t && t !== screen ? t.parentElement.closest('[data-n]') : null;
    const ub = up && up !== screen ? box(up) : null;
    place(hintUp, ub && !near(ub, tb, 4) ? ub : null);
    const db = t && path.length ? box(path[path.length - 1]) : null;
    place(hintDown, db && !near(db, tb, 4) ? db : null);

    place(selEl, drag ? drag.snap || drag.rect : sel);
    selEl.classList.toggle('dragging', !!drag);
    selEl.style.borderRadius = sel ? sel.r.map(v => `${v}px`).join(' ') : '0';
    if (sel) for (const h of selEl.children) h.classList.toggle('f', ['nw', 'ne', 'se', 'sw'].indexOf(h.dataset.h) === sel.focus);
    place(ghost, drag && drag.snap ? drag.rect : null);

    const rad = sel ? Math.max(...sel.r) : t ? +(t.dataset.r || 0) : 0;
    place(framep, on.m && r && !(t && t.dataset.role === 'window') && t !== screen ? { x: r.x - 16, y: r.y - 16, w: r.w + 32, h: r.h + 32 } : null);
    framep.style.borderRadius = `${rad + 16}px`;

    // Size chip above the object, or inside it when there is no room.
    let chip = '';
    if (drag) chip = `${size(r)} ${tag(drag.snap, drag.snap ? 'Snapped' : 'Exact')}`;
    else if (sel) {
      const lo = Math.min(...sel.r), hi = Math.max(...sel.r);
      chip = `${size(sel)} ${tag(sel.snapped, `${sel.snapped ? 'Snapped' : 'Exact'}<span class="kc">S</span>`)}${hi ? `<span class="muted">r ${lo === hi ? hi : `${lo}-${hi}`}</span>` : ''}`;
    } else if (tb) chip = `<b>${t.dataset.n}</b><span class="muted">${size(tb)}</span>`;
    if (chip && on.m) chip += '<span class="muted">+ frame</span>';
    sizeChip.innerHTML = chip;
    sizeChip.hidden = !chip;
    if (chip) {
      const y = r.y - 30;
      at(sizeChip, clamp(r.x, 4, W - sizeChip.offsetWidth - 4), y < 4 ? r.y + 8 : y);
    }

    // Corner group for a Tab-focused corner.
    cornerChip.hidden = !(sel && sel.focus >= 0);
    if (!cornerChip.hidden) {
      cornerChip.innerHTML = `<span><b>${CORNERS[sel.focus]}</b> <span class="muted">r ${sel.r[sel.focus]}</span></span>` +
        '<span class="keys"><span><span class="kc">[</span> <span class="kc">]</span> radius</span><span><span class="kc">tab</span> next corner</span><span><span class="kc">esc</span> all corners</span></span>';
      const cw = cornerChip.offsetWidth, ch = cornerChip.offsetHeight, right = sel.focus === 1 || sel.focus === 2;
      const bottom = sel.focus >= 2;
      let x = right ? sel.x + sel.w + 12 : sel.x - cw - 12, y = bottom ? sel.y + sel.h - ch : sel.y;
      if (x < 4 || x + cw > W - 4) {  // no room beside it: above the chip row, or below the strip
        x = right ? sel.x + sel.w - cw : sel.x;
        y = bottom ? sel.y + sel.h + 42 : sel.y - ch - 36;
        if (y < 4 || y + ch > H - 48) { x = right ? sel.x + sel.w - cw - 12 : sel.x + 12; y = bottom ? sel.y + sel.h - ch - 12 : sel.y + 12; }
      }
      at(cornerChip, clamp(x, 4, W - cw - 4), clamp(y, 4, H - ch - 4));
    }

    // Action strip under the object.
    strip.hidden = !(cap && !drag && (sel || tb));
    if (!strip.hidden) {
      strip.querySelector('.lab').textContent = meta ? 'Agent' : 'Copy';
      const sw = strip.offsetWidth, barTop = H - 48;
      let y = r.y + r.h + 8;
      if (y + 26 > barTop) y = r.y + r.h - 34;
      if (y + 26 > barTop) y = barTop - 30;
      at(strip, clamp(r.x + r.w / 2 - sw / 2, 4, W - sw - 4), y);
    }

    const live = ptr && inStage;
    rulerTop.hidden = rulerLeft.hidden = !on.r;
    if (on.r) {
      const [exT, mkT] = rulerTop.querySelectorAll('i'), [exL, mkL] = rulerLeft.querySelectorAll('i');
      exT.hidden = exL.hidden = !r;
      if (r) Object.assign(exT.style, { left: `${r.x}px`, width: `${r.w}px` }), Object.assign(exL.style, { top: `${r.y - 16}px`, height: `${r.h}px` });
      mkT.hidden = mkL.hidden = !live;
      if (live) { mkT.style.left = `${ptr.x}px`; mkL.style.top = `${ptr.y - 16}px`; }
    }
    cross.hidden = !(on.x && live);
    if (!cross.hidden) { cross.firstElementChild.style.top = `${ptr.y}px`; cross.lastElementChild.style.left = `${ptr.x}px`; }

    cluster.hidden = !(cap && live && !sel && !drag && !on.l);
    if (!cluster.hidden) {
      cluster.innerHTML = `<span>x ${ptr.x}</span><span>y ${ptr.y}</span>${tag(on.s, 'Snap<span class="kc">S</span>')}`;
      const cw = cluster.offsetWidth;
      at(cluster, ptr.x + 16 + cw > W - 4 ? ptr.x - 16 - cw : ptr.x + 16, ptr.y + 40 > H - 48 ? ptr.y - 38 : ptr.y + 18);
    }

    loupe.hidden = readout.hidden = !(on.l && live);
    if (!loupe.hidden) {
      // Above the pointer and clear of the size chip, else below the pointer.
      const D = 120, Z = 4, lx = clamp(ptr.x - D / 2, 4, W - D - 4);
      const above = Math.min(ptr.y - D - 40, sizeChip.hidden ? Infinity : parseFloat(sizeChip.style.top) - D - 36);
      const ly = above < 4 ? ptr.y + 40 : above;
      at(loupe, lx, ly);
      lz.style.transform = `translate(${D / 2 - 2 - ptr.x * Z}px, ${D / 2 - 2 - ptr.y * Z}px) scale(${Z})`;
      const c = colorAt(ptr);
      readout.innerHTML = `<i class="sw" style="background:${hex(c)}"></i>${colorText(c)}<span class="kc">C</span>`;
      at(readout, clamp(lx + D / 2 - readout.offsetWidth / 2, 4, W - readout.offsetWidth - 4), ly + D + 8);
    }
  }

  function fit() {
    screen.classList.toggle('narrow', stage.clientWidth < 720);
    W = screen.offsetWidth;
    H = screen.offsetHeight;
    scale = Math.min(1.08, stage.clientWidth / W);
    screen.style.transform = `scale(${scale})`;
    screen.style.left = `${(stage.clientWidth - W * scale) / 2}px`;
    stage.style.height = `${H * scale}px`;
    Object.assign(lz.style, { width: `${W}px`, height: `${H}px` });
    if (on.l) lz.replaceChildren(scene.cloneNode(true));
    const marks = (n, side) => Array.from({ length: Math.floor(n / 100) }, (_, i) => `<b style="${side}:${(i + 1) * 100 - (side === 'top' ? 16 : 0)}px">${(i + 1) * 100}</b>`).join('');
    rulerTop.innerHTML = `<i class="ex"></i><i class="mk"></i>${marks(W, 'left')}`;
    rulerLeft.innerHTML = `<i class="ex"></i><i class="mk"></i>${marks(H, 'top')}`;
    render();
  }

  /* =====================================================================================
     Agent handoff panel: the reference line and manifest Snug writes, in the shape of HandoffManifest.swift
     ===================================================================================== */
  const agentRef = document.querySelector('.ag-ref'), agentJson = document.querySelector('.ag-json');
  const AX = { row: 'AXRow', button: 'AXButton', table: 'AXTable', group: 'AXGroup', 'web area': 'AXWebArea', 'text field': 'AXTextField',
    outline: 'AXOutline', image: 'AXImage', 'tab group': 'AXRadioGroup', toolbar: 'AXToolbar', link: 'AXLink', folder: 'AXGroup',
    file: 'AXGroup', 'menu bar': 'AXMenuBar', 'menu bar item': 'AXMenuBarItem', 'menu extra': 'AXMenuBarItem' };
  const TITLED = ['row', 'button', 'link', 'folder', 'file', 'menu bar item', 'image'];
  const ID_CHARS = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  function handoff(el, r, name) {
    const id = Array.from({ length: 8 }, () => ID_CHARS[Math.floor(Math.random() * 32)]).join('');
    const win = el && el !== screen ? el.closest('.win') : null;
    const role = el && el !== screen ? el.dataset.role : null;
    const kind = !el ? 'area' : el === screen ? 'display' : role === 'window' ? 'window' : 'element';
    const title = kind === 'window' ? win.dataset.title : TITLED.includes(role) ? name : null;
    const pts = { height: R(r.h), width: R(r.w), x: R(r.x), y: R(r.y) };
    const m = {
      capture_id: id,
      captured_at: new Date().toISOString(),
      geometry: { crop_points: pts },
      image: { file: 'capture.png', height: pts.height * 2, scale: 2, width: pts.width * 2 },
      schema_version: 2,
    };
    if (win) m.source = { app: win.dataset.app, window_title: win.dataset.title };
    m.target = { kind, label: name, provenance: { area: 'user_area', display: 'geometry', window: 'window_list', element: 'accessibility' }[kind] };
    if (kind === 'element') Object.assign(m.target, { role: AX[role], role_description: role });
    if (title) m.target.title = title;
    m.warnings = [];
    const what = (kind === 'element' || kind === 'window' ? role : name).toLowerCase() + (title ? ` "${title}"` : '');
    agentRef.textContent = `[Snug capture ${id}: ${win ? `${win.dataset.app}, ` : ''}${what}, ${pts.width} x ${pts.height} pt. Use the snug MCP tool get_capture to see it.]`;
    // Short objects that hold only plain values print on one line.
    agentJson.innerHTML = JSON.stringify(m, null, 2).replace(/\{\n([^{}[\]]*?)\n\s*\}/g, (all, body) => {
      const line = `{ ${body.trim().split(/,\n\s*/).join(', ')} }`;
      return line.length < 64 ? line : all;
    })
      .replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/("(?:[^"\\]|\\.)*")(\s*:)?|\b(\d+(?:\.\d+)?)\b/g, (_, str, colon, num) =>
        str ? `<span class="${colon ? 'k' : 's'}">${str}</span>${colon || ''}` : `<span class="n">${num}</span>`);
    for (const x of [agentRef, agentJson]) { x.classList.remove('fresh'); void x.offsetWidth; x.classList.add('fresh'); }
    return id;
  }

  /* =====================================================================================
     Vignettes
     ===================================================================================== */

  // Text: select text in a "screenshot", Return copies.
  const vt = document.querySelector('.vt'), vtPre = vt.querySelector('pre'), vtStrip = vt.querySelector('.tstrip');
  let vtDown = false;
  function vtSel() {
    const s = getSelection();
    return !s.isCollapsed && vtPre.contains(s.anchorNode) && vtPre.contains(s.focusNode) ? s : null;
  }
  function vtSync() {
    const s = vtSel();
    vtStrip.hidden = !s || vtDown;
    if (vtStrip.hidden) return;
    const r = s.getRangeAt(0).getBoundingClientRect(), v = vt.getBoundingClientRect();
    vtStrip.style.left = `${clamp(r.left - v.left + r.width / 2 - 34, 8, v.width - 80)}px`;
    vtStrip.style.top = `${Math.min(r.bottom - v.top + 8, v.height - 36)}px`;
  }
  function vtCopy() {
    const s = vtSel();
    if (!s) return false;
    const n = s.toString().split('\n').filter(l => l.trim()).length;
    toast('Copied', `${n} line${n === 1 ? '' : 's'} of text`);
    s.removeAllRanges();
    return true;
  }
  document.addEventListener('selectionchange', vtSync);
  vtPre.addEventListener('pointerdown', () => { vtDown = true; vtSync(); });
  addEventListener('pointerup', () => { if (vtDown) { vtDown = false; vtSync(); } });
  vtStrip.addEventListener('pointerdown', e => e.preventDefault());
  vtStrip.addEventListener('click', vtCopy);
  keyed.push([vt, e => e.key === 'Enter' && vtCopy()]);

  // Scrolling capture: the stitched height follows the scroll, and a minimap shows it.
  const vs = document.querySelector('.vs'), pane = vs.querySelector('.vs-pane'), list = vs.querySelector('.vs-list');
  const mini = vs.querySelector('.vs-mini'), miniIn = mini.firstElementChild, miniView = mini.lastElementChild, vsChip = vs.querySelector('.vs-chip');
  list.innerHTML = [
    ['Cedar Loop', 'Mud at the second creek crossing.', 'Oct 18'], ['Lookout Ridge', 'Clear to the summit by ten.', 'Oct 17'],
    ['Fern Hollow', 'Bridge repaired, all open.', 'Oct 15'], ['Old Mill', 'Loose rock on the last mile.', 'Oct 14'],
    ['Cedar Loop', 'Trail crew on site Saturday.', 'Oct 12'], ['Lookout Ridge', 'Wind picked up after noon.', 'Oct 11'],
    ['Fern Hollow', 'Leaves down, slick in spots.', 'Oct 9'], ['Old Mill', 'Parking lot full by eight.', 'Oct 8'],
    ['Cedar Loop', 'First frost on the meadow.', 'Oct 6'], ['Lookout Ridge', 'New trail markers posted.', 'Oct 5'],
    ['Fern Hollow', 'Quiet, two other hikers.', 'Oct 3'], ['Old Mill', 'Creek running high.', 'Oct 2'],
  ].map(([t, d, when]) => `<div class="vs-item"><i>${when}</i><b>${t}</b><span>${d}</span></div>`).join('');
  const miniClone = list.cloneNode(true);
  miniIn.append(miniClone);
  function vsSync() {
    const ph = pane.clientHeight, pw = pane.clientWidth, total = pane.scrollTop + ph;
    const k = Math.min(64 / pw, (ph - 20) / total);
    Object.assign(miniClone.style, { width: `${pw}px`, transform: `scale(${k})` });
    mini.style.width = `${pw * k}px`;
    miniIn.style.height = `${total * k}px`;
    Object.assign(miniView.style, { top: `${pane.scrollTop * k}px`, height: `${ph * k}px` });
    vsChip.textContent = `Scrolling ${R(total * 2)} px`;
  }
  function vsCopy() {
    toast('Copied', `Scrolling capture, ${R(pane.clientWidth * 2)} x ${R((pane.scrollTop + pane.clientHeight) * 2)} px`,
      { aspect: pane.clientWidth / (pane.scrollTop + pane.clientHeight) });
    return true;
  }
  pane.addEventListener('scroll', vsSync, { passive: true });
  new ResizeObserver(vsSync).observe(pane);
  vs.querySelector('.vs-copy').addEventListener('click', vsCopy);
  keyed.push([vs, e => e.key === 'Enter' && vsCopy()]);

  // Recording: V arms, V or Return starts after a count-in, the shortcut stops.
  const vr = document.querySelector('.vr'), vrChip = vr.querySelector('.vr-chip'), vrLabel = vr.querySelector('.vr-label'), vrCap = vr.querySelector('.vr-cap');
  let recState = 'idle', recT = 0, recN = 0, recStart = 0;
  const elapsed = () => { const s = Math.floor((Date.now() - recStart) / 1000); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
  function recSet(s) {
    recState = s;
    vr.dataset.state = s;
    vrLabel.textContent = { idle: 'Record', armed: 'Start', rec: 'Stop' }[s] || '';
    vrCap.textContent = s === 'armed' ? '\u21A9' : 'V';
    vrCap.hidden = s === 'rec';
  }
  function recTick() {
    if (recState === 'count' && recN > 0) { vrChip.textContent = `Recording in ${recN--}`; recT = setTimeout(recTick, 1000); return; }
    if (recState === 'count') { recSet('rec'); recStart = Date.now(); }
    vrChip.innerHTML = `<i class="dot"></i>${elapsed()}`;
    recT = setTimeout(recTick, 250);
  }
  function recGo() {
    if (recState === 'idle') recSet('armed');
    else if (recState === 'armed') { recSet('count'); recN = 3; recTick(); }
    else if (recState === 'rec') stopRec();
  }
  function stopRec() {
    clearTimeout(recT);
    toast('Recording saved', `${elapsed()}, movie`, { aspect: 16 / 10 });
    recSet('idle');
  }
  vr.querySelector('.vr-go').addEventListener('click', recGo);
  vr.querySelector('.vr-cancel').addEventListener('click', () => { clearTimeout(recT); recSet('idle'); });
  keyed.push([vr, e => {
    const k = e.key.toLowerCase();
    if ((k === 'v' && recState !== 'rec') || (k === 'enter' && recState === 'armed')) { recGo(); return true; }
    if (k === 'escape' && (recState === 'armed' || recState === 'count')) { clearTimeout(recT); recSet('idle'); return true; }
    return false;
  }]);

  // Subject: K lifts the subject off its background; K or Esc goes back.
  const vk = document.querySelector('.vk');
  vk.querySelector('.vk-key').addEventListener('click', () => vk.classList.toggle('cut'));
  keyed.push([vk, e => {
    const k = e.key.toLowerCase(), cut = vk.classList.contains('cut');
    if (k === 'k' || (k === 'escape' && cut)) { vk.classList.toggle('cut'); return true; }
    if (k === 'enter' && cut) { toast('Copied', 'Subject, transparent background', { aspect: 100 / 130 }); return true; }
    return false;
  }]);

  // Color: point at the gradient; click or C copies, Shift-C changes the format.
  const vc = document.querySelector('.vc'), grad = vc.querySelector('.vc-grad'), vcRead = vc.querySelector('.vc-read'), vcFmt = vc.querySelector('.vc-fmt');
  const STOPS = [[58, 35, 64], [123, 63, 97], [255, 122, 107], [255, 179, 138], [255, 227, 194]];
  let vcColor = STOPS[2];
  grad.style.background = `linear-gradient(90deg, ${STOPS.map(hex).join(', ')})`;
  function syncFormat() {
    vcFmt.firstChild.textContent = FORMATS[fmtI];
    vcRead.querySelector('.vc-val').textContent = colorText(vcColor);
  }
  function vcCopy() {
    toast(`Copied ${colorText(vcColor)}`, `${FORMATS[fmtI]} color`, { swatch: hex(vcColor) });
    return true;
  }
  grad.addEventListener('pointermove', e => {
    const g = grad.getBoundingClientRect(), v = vc.getBoundingClientRect();
    const t = clamp((e.clientX - g.left) / g.width, 0, 1) * (STOPS.length - 1), i = Math.min(Math.floor(t), STOPS.length - 2), f = t - i;
    vcColor = STOPS[i].map((a, j) => R(a + (STOPS[i + 1][j] - a) * f));
    vcRead.querySelector('.sw').style.background = hex(vcColor);
    syncFormat();
    vcRead.style.display = 'inline-flex';
    const x = e.clientX - v.left + 14, w = vcRead.offsetWidth;
    vcRead.style.left = `${x + w > v.width - 8 ? x - w - 28 : x}px`;
    vcRead.style.top = `${e.clientY - v.top + 14}px`;
  });
  grad.addEventListener('pointerleave', () => { vcRead.style.display = ''; });
  grad.addEventListener('click', vcCopy);
  vcFmt.addEventListener('click', () => { fmtI = (fmtI + 1) % FORMATS.length; syncFormat(); });
  keyed.push([vc, e => {
    if (e.key === 'c') return vcCopy();
    if (e.key === 'C') { fmtI = (fmtI + 1) % FORMATS.length; syncFormat(); return true; }
    return false;
  }]);

  // Frame and rounded corners: M and O change the output preview.
  const vf = document.querySelector('.vf'), vfCard = vf.querySelector('.vf-card'), vfSize = vf.querySelector('.vf-size');
  function vfSync() {
    for (const b of vf.querySelectorAll('.vf-tog')) b.classList.toggle('lit', vf.classList.contains(b.dataset.k));
    const w = vfCard.offsetWidth, h = vfCard.offsetHeight;
    vfSize.textContent = vf.classList.contains('m') ? `${w} x ${h} + frame ${w + 48} x ${h + 48}` : `${w} x ${h}`;
  }
  vf.addEventListener('click', e => {
    const b = e.target.closest('.vf-tog');
    if (b) { vf.classList.toggle(b.dataset.k); vfSync(); }
  });
  keyed.push([vf, e => {
    const k = e.key.toLowerCase();
    if (k === 'm' || k === 'o') { vf.classList.toggle(k); vfSync(); return true; }
    if (k === 'enter') { toast('Copied', vfSize.textContent, { aspect: 2.6 }); return true; }
    return false;
  }]);

  document.querySelector('.ag-copy').addEventListener('click', () => {
    navigator.clipboard.writeText(document.querySelector('.cmd code').textContent).then(() => toast('Copied', 'The MCP command'));
  });

  /* ---------- start ---------- */
  addEventListener('resize', fit);
  fit();
  vsSync();
  vfSync();
  syncFormat();
  handoff(scene.querySelector('[data-n="Downloads"]'), box(scene.querySelector('[data-n="Downloads"]')), 'Downloads');
  agentRef.classList.remove('fresh');
  agentJson.classList.remove('fresh');
  say('Point at anything in the drawing. Click or press Return to copy.');
})();
