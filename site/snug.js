// The hero demo: a scripted Snug overlay over a mock desktop. It hovers an element, then drags a loose box that snaps to the card
// under it on a pause, and copies. Visitors can hover, drag (Option keeps the box exact), walk with Up and Down, and press Return;
// the script picks up again after a few idle seconds.
(() => {
  'use strict';
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const IDLE_MS = 4000;

  /* every box in scene px, parents before children; r is the element's corner radius */
  const BOX = {
    screen: { n: 'Full screen', x: 0, y: 0, w: 640, h: 400, p: null, r: 0 },
    menubar: { n: 'Menu bar', x: 0, y: 0, w: 640, h: 22, p: 'screen', r: 0 },
    win: { n: 'Safari window', x: 36, y: 40, w: 568, h: 336, p: 'screen', r: 12 },
    toolbar: { n: 'Toolbar', x: 36, y: 40, w: 568, h: 38, p: 'win', r: 0 },
    chart: { n: 'Elevation chart', x: 60, y: 128, w: 256, h: 134, p: 'win', r: 10 },
    cond: { n: 'Conditions', x: 328, y: 128, w: 252, h: 134, p: 'win', r: 10 },
    trail: { n: 'Trail', x: 340, y: 166, w: 70, h: 82, p: 'cond', r: 7 },
    wind: { n: 'Wind', x: 418, y: 166, w: 70, h: 82, p: 'cond', r: 7 },
    sunset: { n: 'Sunset', x: 496, y: 166, w: 70, h: 82, p: 'cond', r: 7 },
    table: { n: 'Routes table', x: 60, y: 274, w: 520, h: 90, p: 'win', r: 8 },
    row1: { n: 'Cedar Loop', x: 60, y: 297, w: 520, h: 22, p: 'table', r: 0 },
    row2: { n: 'Lookout Ridge', x: 60, y: 319, w: 520, h: 22, p: 'table', r: 0 },
    row3: { n: 'Fern Hollow', x: 60, y: 341, w: 520, h: 23, p: 'table', r: 0 },
  };
  const KEYS = Object.keys(BOX);
  const at = k => `left:${BOX[k].x}px;top:${BOX[k].y}px;width:${BOX[k].w}px;height:${BOX[k].h}px`;
  const stat = (k, label, val) => `<div class="b s-stat" style="${at(k)}"><small>${label}</small><b>${val}</b></div>`;
  const row = (k, a, b, c) => `<div class="b s-row" style="${at(k)}"><span>${a}</span><span>${b}</span><span>${c}</span></div>`;
  const SCENE = `
    <div class="b s-screen" style="${at('screen')}"></div>
    <div class="b s-menubar" style="${at('menubar')}"><b>Safari</b><span>File</span><span>Edit</span><span>View</span><span>History</span><span class="clock">Mon Oct 19 9:41</span></div>
    <div class="b s-win" style="${at('win')}"></div>
    <div class="b s-toolbar" style="${at('toolbar')}"><span class="s-lights"><i></i><i></i><i></i></span><span class="s-addr">trail-log.example</span></div>
    <div class="b s-title" style="left:60px;top:88px">Weekend routes<small>Four loops within an hour of town.</small></div>
    <div class="b s-card" style="${at('chart')}"><h4>Elevation gain</h4><div class="s-bars"><i style="height:45%"></i><i style="height:95%"></i><i style="height:30%"></i><i style="height:70%"></i></div></div>
    <div class="b s-card" style="${at('cond')}"><h4>Conditions</h4></div>
    ${stat('trail', 'Trail', 'Dry')}${stat('wind', 'Wind', '8 mph')}${stat('sunset', 'Sunset', '6:42')}
    <div class="b s-table" style="${at('table')}"><div class="s-row h" style="height:23px"><span>Route</span><span>Distance</span><span>Gain</span></div></div>
    ${row('row1', 'Cedar Loop', '4.2 mi', '620 ft')}${row('row2', 'Lookout Ridge', '7.8 mi', '1,940 ft')}${row('row3', 'Fern Hollow', '3.1 mi', '310 ft')}
    <div class="ov">
      <div class="o-hint"></div><div class="o-hl"></div><div class="o-ghost"></div><div class="o-sel"></div><div class="o-flash"></div>
      <div class="o-chip"></div><div class="o-strip">Copy <i>&#8617;</i></div>
      <div class="o-toast"><span class="th"><i></i></span><span><b>Copied</b><em></em></span></div>
      <div class="o-cast out" hidden></div>
      <div class="o-cursor"><svg viewBox="0 0 16 24" width="15" height="22"><path d="M1.5 1.5v17.2l4.3-4.1 2.9 6.6 3-1.3-2.9-6.5h6z" fill="#111" stroke="#fff" stroke-width="1.4" stroke-linejoin="round"/></svg></div>
    </div>`;

  const size = r => `${Math.round(r.w)} x ${Math.round(r.h)}`;
  const inside = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
  // The innermost element under the point; the bare desktop picks nothing.
  const hit = p => KEYS.filter(k => k !== 'screen' && inside(BOX[k], p)).pop() || null;
  const same = (a, b) => a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
  // The corner radius of the element a rectangle lands on exactly, else square.
  const radiusOf = r => { const k = KEYS.find(k => same(BOX[k], r)); return k ? BOX[k].r : 0; };
  // Snap: each edge of a dragged box moves to the nearest element edge within 10 px beside it.
  function snapRect(r) {
    const boxes = KEYS.map(k => BOX[k]);
    const to = (v, list) => { let best = v, d = 10.5; for (const c of list) if (Math.abs(c - v) < d) { d = Math.abs(c - v); best = c; } return best; };
    const xs = boxes.filter(b => b.y < r.y + r.h && b.y + b.h > r.y).flatMap(b => [b.x, b.x + b.w]);
    const ys = boxes.filter(b => b.x < r.x + r.w && b.x + b.w > r.x).flatMap(b => [b.y, b.y + b.h]);
    const x1 = to(r.x, xs), y1 = to(r.y, ys), x2 = to(r.x + r.w, xs), y2 = to(r.y + r.h, ys);
    return { x: x1, y: y1, w: Math.max(4, x2 - x1), h: Math.max(4, y2 - y1) };
  }

  class Demo {
    constructor(el) {
      this.el = el;
      this.gen = 0;
      el.tabIndex = 0;
      el.setAttribute('role', 'application');
      el.setAttribute('aria-label', 'Demo of the Snug overlay. Hover to pick an element, or drag a box and pause to snap it; Return copies.');
      el.innerHTML = `<div class="scene" data-open="true">${SCENE}</div>`;
      this.scene = el.querySelector('.scene');
      const q = s => this.scene.querySelector(s);
      Object.assign(this, { hint: q('.o-hint'), hl: q('.o-hl'), ghost: q('.o-ghost'), sel: q('.o-sel'), flash: q('.o-flash'), chip: q('.o-chip'), strip: q('.o-strip'), toast: q('.o-toast'), cast: q('.o-cast'), cursor: q('.o-cursor') });
      this.s = { open: true, target: 'win', drag: null, selr: null, path: [] };
      this.ptr = { x: 300, y: 112 };
      new ResizeObserver(() => { this.scene.style.transform = `scale(${el.clientWidth / 640})`; }).observe(el);
      this.bindUser();
      if (reduce) this.still(); else this.play();
    }

    place(el, r) {
      el.hidden = !r;
      if (r) Object.assign(el.style, { left: `${r.x}px`, top: `${r.y}px`, width: `${r.w}px`, height: `${r.h}px`, borderRadius: `${r.r || 0}px` });
    }
    pos(el, x, y) { el.hidden = false; el.style.left = `${x}px`; el.style.top = `${y}px`; }
    aim(p) { this.ptr = p; this.cursor.style.transform = `translate(${p.x}px, ${p.y}px)`; }

    render() {
      const s = this.s;
      this.scene.dataset.open = String(s.open);
      if (!s.open) return;
      const t = !s.drag && !s.selr ? s.target : null, tb = t && BOX[t];
      this.place(this.hl, tb);
      const up = t && BOX[t].p && BOX[t].p !== 'screen' ? BOX[BOX[t].p] : null;
      this.place(this.hint, up);
      const r = s.drag ? (s.drag.snap || s.drag.raw) : s.selr;
      this.place(this.sel, r && { ...r, r: s.drag && !s.drag.snap ? 0 : radiusOf(r) });
      this.place(this.ghost, s.drag && s.drag.snap ? s.drag.raw : null);
      const tag = on => `<span class="tag${on ? ' lit' : ''}">${on ? 'Snapped' : 'Exact'}</span>`;
      this.chip.innerHTML = s.drag ? `${size(r)} ${tag(!!s.drag.snap)}` : s.selr ? `${size(r)} ${tag(s.selr.snapped)}` : tb ? `<b>${tb.n}</b><span class="mut">${size(tb)}</span>` : '';
      const cr = r || tb;
      this.chip.hidden = !cr;
      if (cr) { const y = cr.y - 29; this.pos(this.chip, Math.max(4, Math.min(cr.x, 640 - this.chip.offsetWidth - 4)), y < 26 ? cr.y + 8 : y); }
      this.strip.hidden = !(!s.drag && cr);
      if (!this.strip.hidden) {
        let y = cr.y + cr.h + 8;
        if (y + 24 > 396) y = cr.y + cr.h - 32;
        this.pos(this.strip, Math.max(4, Math.min(cr.x + cr.w / 2 - this.strip.offsetWidth / 2, 640 - this.strip.offsetWidth - 4)), y);
      }
    }

    keyCast(text) {
      this.cast.textContent = text;
      this.pos(this.cast, Math.min(this.ptr.x + 16, 600), Math.min(this.ptr.y + 22, 370));
      this.cast.classList.remove('out');
      clearTimeout(this.castT);
      this.castT = setTimeout(() => this.cast.classList.add('out'), 700);
    }
    copy() {
      const s = this.s, r = s.selr || (s.target && BOX[s.target]);
      if (!r) return;
      const radius = s.selr ? radiusOf(r) : r.r;
      this.place(this.flash, { ...r, r: radius });
      this.flash.classList.remove('go'); void this.flash.offsetWidth; this.flash.classList.add('go');
      const th = this.toast.querySelector('i'), a = r.w / r.h, k = 32 / Math.max(r.w, r.h);
      th.style.width = `${a >= 1 ? 32 : 32 * a}px`; th.style.height = `${a >= 1 ? 32 / a : 32}px`;
      th.style.borderRadius = `${Math.max(2, radius * k)}px`;
      this.toast.querySelector('em').textContent = s.selr ? `Area, ${size(r)}` : `${BOX[s.target].n}, ${size(r)}`;
      this.toast.classList.add('show');
      clearTimeout(this.toastT);
      this.toastT = setTimeout(() => this.toast.classList.remove('show'), 2200);
      setTimeout(() => { s.open = false; s.selr = null; s.drag = null; this.render(); }, reduce ? 0 : 260);
    }

    /* ---------- autoplay ---------- */
    play() {
      const gen = ++this.gen;
      this.cursor.hidden = false;
      const sleep = ms => new Promise((ok, no) => setTimeout(() => (gen === this.gen ? ok() : no(gen)), ms));
      const glide = (to, ms, each) => new Promise((ok, no) => {
        const a = { ...this.ptr }, t0 = performance.now();
        const step = now => {
          if (gen !== this.gen) return no(gen);
          const k = Math.min(1, (now - t0) / ms), e = k < .5 ? 2 * k * k : 1 - 2 * (1 - k) ** 2;
          this.aim({ x: a.x + (to.x - a.x) * e, y: a.y + (to.y - a.y) * e });
          each();
          this.render();
          k < 1 ? requestAnimationFrame(step) : ok();
        };
        requestAnimationFrame(step);
      });
      const hover = () => { this.s.target = hit(this.ptr); };
      const loop = async () => {
        for (;;) {
          const s = this.s;
          Object.assign(s, { open: true, drag: null, selr: null, path: [] });
          // Hover: the chart card lights up with its own rounded corners.
          this.aim({ x: 250, y: 330 }); hover(); this.render();
          await sleep(500);
          await glide({ x: 170, y: 205 }, 700, hover);
          await sleep(1300);
          // Drag a loose box around the Conditions card, pause, and it snaps.
          await glide({ x: 323, y: 122 }, 650, hover);
          await sleep(200);
          const start = { ...this.ptr };
          s.drag = { raw: { x: start.x, y: start.y, w: 0, h: 0 }, snap: null };
          await glide({ x: 586, y: 267 }, 1000, () => {
            s.drag.raw = { x: start.x, y: start.y, w: this.ptr.x - start.x, h: this.ptr.y - start.y };
          });
          await sleep(160);
          this.sel.classList.add('spring');
          s.drag.snap = snapRect(s.drag.raw);
          this.render();
          await sleep(1300);
          this.sel.classList.remove('spring');
          s.selr = { ...s.drag.snap, snapped: true }; s.drag = null; this.render();
          await sleep(900);
          this.keyCast('↩'); this.copy();
          await sleep(2400);
        }
      };
      loop().catch(g => { if (typeof g !== 'number') throw g; });
    }
    stop() { this.gen++; this.cursor.hidden = true; this.sel.classList.remove('spring'); }
    still() {
      this.cursor.hidden = true;
      const raw = { x: 323, y: 122, w: 263, h: 145 };
      Object.assign(this.s, { open: true, selr: null, drag: { raw, snap: snapRect(raw) } });
      this.render();
    }

    /* ---------- the visitor drives; the script resumes after a few idle seconds ---------- */
    bindUser() {
      const el = this.el, s = this.s;
      const toScene = e => { const b = this.scene.getBoundingClientRect(), k = b.width / 640; return { x: (e.clientX - b.left) / k, y: (e.clientY - b.top) / k }; };
      let grab = null, snapT = 0, idleT = 0, driving = false;
      const touch = () => {
        if (!driving) { driving = true; this.stop(); }
        clearTimeout(idleT);
        if (!reduce) idleT = setTimeout(() => { if (grab) return touch(); driving = false; this.toast.classList.remove('show'); this.play(); }, IDLE_MS);
      };
      el.addEventListener('pointerdown', e => {
        if (e.button !== 0) return;
        touch();
        e.preventDefault();
        el.focus({ preventScroll: true });
        const p = toScene(e);
        this.ptr = p;
        if (!s.open) { s.open = true; s.selr = null; s.target = hit(p); this.render(); return; }
        grab = { start: p, moved: false, id: e.pointerId };
        el.setPointerCapture(e.pointerId);
      });
      el.addEventListener('pointermove', e => {
        // A mouse over the demo takes over; touch only takes over with a press.
        if (!driving && e.pointerType !== 'mouse') return;
        touch();
        const p = toScene(e);
        this.ptr = p;
        if (!s.open) return;
        if (!grab) { if (!s.selr) { s.target = hit(p); this.render(); } return; }
        if (!grab.moved && Math.hypot(p.x - grab.start.x, p.y - grab.start.y) < 4) return;
        grab.moved = true; s.selr = null;
        const raw = { x: Math.min(grab.start.x, p.x), y: Math.min(grab.start.y, p.y), w: Math.abs(p.x - grab.start.x), h: Math.abs(p.y - grab.start.y) };
        const keep = !e.altKey && s.drag && s.drag.snap && same(snapRect(raw), s.drag.snap);
        s.drag = { raw, snap: keep ? s.drag.snap : null };
        clearTimeout(snapT);
        // A short rest previews the snap, as in the app; Option keeps the box exact.
        if (!keep && !e.altKey) snapT = setTimeout(() => {
          if (!s.drag) return;
          const sn = snapRect(s.drag.raw);
          this.sel.classList.add('spring');
          s.drag.snap = same(sn, s.drag.raw) ? null : sn;
          this.render();
          setTimeout(() => this.sel.classList.remove('spring'), 170);
        }, 80);
        this.render();
      });
      el.addEventListener('pointerup', e => {
        if (!grab) return;
        clearTimeout(snapT);
        const g = grab; grab = null;
        if (g.moved && s.drag) {
          const r = s.drag.snap && !e.altKey ? s.drag.snap : s.drag.raw;
          s.selr = { ...r, snapped: r === s.drag.snap }; s.drag = null;
        } else if (s.selr && !inside(s.selr, this.ptr)) { s.selr = null; s.target = hit(this.ptr); }
        else this.copy();
        this.render();
      });
      el.addEventListener('pointercancel', () => { grab = null; s.drag = null; this.render(); });
      el.addEventListener('keydown', e => {
        if (!s.open) { if (e.key === 'Enter') { touch(); s.open = true; this.render(); e.preventDefault(); } return; }
        if (e.key === 'Enter') { touch(); this.keyCast('↩'); this.copy(); }
        else if (e.key === 'Escape') { touch(); if (s.selr) s.selr = null; else s.open = false; this.render(); }
        else if (e.key === 'ArrowUp' && !s.selr && s.target && BOX[s.target].p && BOX[s.target].p !== 'screen') { touch(); s.path.push(s.target); s.target = BOX[s.target].p; this.keyCast('↑'); this.render(); }
        else if (e.key === 'ArrowDown' && !s.selr && s.path.length) { touch(); s.target = s.path.pop(); this.keyCast('↓'); this.render(); }
        else return;
        e.preventDefault();
      });
    }
  }

  for (const el of document.querySelectorAll('.demo')) new Demo(el);
})();
