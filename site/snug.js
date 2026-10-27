// The hero demo: a scripted Snug overlay over a mock desktop, drawn the way the app draws it (Sources/Snug/OverlayView.swift and
// Chrome.swift). The script hovers elements, drags a loose box that snaps to the card under it on a pause, and copies. A visitor's
// pointer takes over at once; the script picks up again shortly after the pointer leaves, or after a few idle seconds on touch.
// Under 600 px wide the demo is watch-only: it crops to the chat window, plays its own short script and ignores input.
(() => {
  'use strict';
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const W = 640, H = 400, MENU = 22;
  const LEAVE_MS = 1200, TOUCH_IDLE_MS = 4000;
  const NS = 'http://www.w3.org/2000/svg';
  const phoneQ = matchMedia('(max-width: 599.98px)');

  /* Every box in scene px, parents before children. r is the element's own corner radii [top-left, top-right, bottom-right,
     bottom-left]; a square corner that sits on a corner of its parent takes the parent's radius, as the app gives a window's corner
     radius to the corners an element shares with its window (OverlayController.swift cornerRadii(of:)). */
  const BOX = {
    screen: { n: 'Full screen', x: 0, y: 0, w: 640, h: 400, p: null, r: [0, 0, 0, 0] },
    menubar: { n: 'Menu bar', x: 0, y: 0, w: 640, h: 22, p: 'screen', r: [0, 0, 0, 0] },
    // The review window, left of the chat window with a 16 px gap between them, as from each desktop edge; both start at the same top.
    rv: { n: 'Review', x: 16, y: 58, w: 348, h: 328, p: 'screen', r: [12, 12, 12, 12] },
    rvbar: { n: 'Toolbar', x: 16, y: 58, w: 348, h: 34, p: 'rv', r: [0, 0, 0, 0] },
    rvfile: { n: 'Header.css', x: 30, y: 140, w: 320, h: 238, p: 'rv', r: [8, 8, 8, 8] },
    rvhead: { n: 'File header', x: 30, y: 140, w: 320, h: 26, p: 'rvfile', r: [0, 0, 0, 0] },
    l1: { n: 'Line 12', x: 30, y: 166, w: 320, h: 18, p: 'rvfile', r: [0, 0, 0, 0] },
    l2: { n: 'Line 13', x: 30, y: 184, w: 320, h: 18, p: 'rvfile', r: [0, 0, 0, 0] },
    l3: { n: 'Removed line 14', x: 30, y: 202, w: 320, h: 18, p: 'rvfile', r: [0, 0, 0, 0] },
    l4: { n: 'Added line 14', x: 30, y: 220, w: 320, h: 18, p: 'rvfile', r: [0, 0, 0, 0] },
    l5: { n: 'Added line 15', x: 30, y: 238, w: 320, h: 18, p: 'rvfile', r: [0, 0, 0, 0] },
    rvc: { n: 'Review comment', x: 46, y: 274, w: 288, h: 62, p: 'rvfile', r: [8, 8, 8, 8] },
    l6: { n: 'Line 16', x: 30, y: 354, w: 320, h: 18, p: 'rvfile', r: [0, 0, 0, 0] },
    // The chat window, to its right.
    ch: { n: 'Chat', x: 380, y: 58, w: 244, h: 328, p: 'screen', r: [12, 12, 12, 12] },
    chbar: { n: 'Toolbar', x: 380, y: 58, w: 244, h: 34, p: 'ch', r: [0, 0, 0, 0] },
    b1: { n: 'Message', x: 392, y: 116, w: 176, h: 40, p: 'ch', r: [13, 13, 13, 13] },
    b2: { n: 'Message', x: 462, y: 162, w: 150, h: 26, p: 'ch', r: [13, 13, 13, 13] },
    b3: { n: 'Message', x: 428, y: 194, w: 184, h: 98, p: 'ch', r: [13, 13, 13, 13] },
    lk: { n: 'Link preview', x: 434, y: 216, w: 172, h: 70, p: 'b3', r: [9, 9, 9, 9] },
    b4: { n: 'Message', x: 392, y: 300, w: 166, h: 26, p: 'ch', r: [13, 13, 13, 13] },
    cm: { n: 'Message field', x: 390, y: 340, w: 224, h: 32, p: 'ch', r: [16, 16, 16, 16] },
  };
  const KEYS = Object.keys(BOX);
  // The review window's boxes: out of the picture, and out of the snap and hit tests, on a phone.
  const RV = ['rv', 'rvbar', 'rvfile', 'rvhead', 'l1', 'l2', 'l3', 'l4', 'l5', 'rvc', 'l6'];
  let LIVE = KEYS;
  /* The part of the scene on show, and the script that plays over it. tour: pointer stops [x, y, glide ms, hold ms]; the drag starts
     at `from`, ends at `to` and snaps on a pause; `after` is where the pointer rests before Return. The phone drags a rough box
     around the link preview. */
  const DESK = { view: { x: 0, y: 0, w: W, h: H }, tour: [[480, 136, 800, 1100], [520, 262, 700, 1200], [205, 229, 850, 1200]],
    from: [40, 268, 650], to: [340, 342, 1000], after: [240, 304] };
  const PHONE = { view: { x: 372, y: 0, w: 260, h: 332 }, tour: [[480, 136, 800, 1100], [520, 262, 700, 1200]],
    from: [440, 222, 600], to: [600, 280, 900], after: [556, 268] };
  const ZERO = [0, 0, 0, 0];
  // Corner points in r's order.
  const cornerAt = (b, i) => [[b.x, b.y], [b.x + b.w, b.y], [b.x + b.w, b.y + b.h], [b.x, b.y + b.h]][i];
  const radiiOf = k => BOX[k].r.map((own, i) => {
    if (own) return own;
    const [cx, cy] = cornerAt(BOX[k], i);
    for (let p = BOX[k].p; p; p = BOX[p].p) {
      const [px, py] = cornerAt(BOX[p], i);
      if (px !== cx || py !== cy) break;
      if (BOX[p].r[i]) return BOX[p].r[i];
    }
    return 0;
  });
  for (const k of KEYS) BOX[k].radii = radiiOf(k);

  const at = k => `left:${BOX[k].x}px;top:${BOX[k].y}px;width:${BOX[k].w}px;height:${BOX[k].h}px`;
  const lights = '<span class="s-lights"><i></i><i></i><i></i></span>';
  // A diff line: old and new line numbers, the +/- mark, and the code.
  const line = (k, kind, o, n, code) => `<div class="b s-ln ${kind}" style="${at(k)}"><span class="no">${o}</span><span class="no">${n}</span>`
    + `<span class="mk">${kind === 'add' ? '+' : kind === 'del' ? '&minus;' : ''}</span><code>${code}</code></div>`;
  const bub = (k, side, html) => `<div class="b s-bub ${side}" style="${at(k)}">${html}</div>`;
  const CONTENT = `
    <div class="b s-screen" style="${at('screen')}"></div>
    <div class="b s-menubar" style="${at('menubar')}"><b>Chat</b><span>File</span><span>Edit</span><span>View</span><span>Window</span><span class="clock">Mon Oct 26 9:41</span></div>
    <div class="rvg"><div class="b s-win" style="${at('rv')}"></div>
    <div class="b s-toolbar" style="${at('rvbar')}">${lights}<span class="s-wt">Review</span></div>
    <div class="b s-pr" style="left:32px;top:98px;width:316px">Round the chat avatars<small><span class="s-tag">Ready</span>#218 &middot; 1 file &middot; <ins>+2</ins> <del>&minus;1</del></small></div>
    <div class="b s-file" style="${at('rvfile')}"></div>
    <div class="b s-fhead" style="${at('rvhead')}"><code>src/chat/Header.css</code><span><ins>+2</ins> <del>&minus;1</del></span></div>
    ${line('l1', 'ctx', 12, 12, '.avatar {')}${line('l2', 'ctx', 13, 13, '  width: 28px;')}${line('l3', 'del', 14, '', '  border-radius: 4px;')}
    ${line('l4', 'add', '', 14, '  border-radius: 50%;')}${line('l5', 'add', '', 15, '  object-fit: cover;')}
    <div class="b s-cmt" style="${at('rvc')}"><i class="av a2"></i><div><b>Rae</b> <small>on line 14</small><p>50% keeps it round at any size. Nice.</p><small class="act">Reply &middot; Resolve</small></div></div>
    ${line('l6', 'ctx', 15, 16, '}')}</div>
    <div class="b s-win" style="${at('ch')}"></div>
    <div class="b s-toolbar" style="${at('chbar')}">${lights}<span class="s-wt"><i class="av a2"></i>Rae</span></div>
    <div class="b s-ts" style="left:380px;top:98px;width:244px">Today 9:38</div>
    ${bub('b1', 'in', 'Avatars in the header get clipped on small screens')}
    ${bub('b2', 'out', 'On it, rounding them now')}
    ${bub('b3', 'out', 'PR is up, take a look')}
    <div class="b s-link" style="${at('lk')}"><span class="th"><i></i><i></i><i></i></span><b>Round the chat avatars</b><small>review.example &middot; #218</small></div>
    ${bub('b4', 'in', 'Looks great, approving now')}
    <div class="b s-ts" style="left:564px;top:307px">9:41</div>
    <div class="b s-field" style="${at('cm')}">Message</div>`;

  // The strip's tool symbols, drawn after the SF Symbols the app uses (Chrome.swift: arrow.down.document, record.circle,
  // person.crop.rectangle, eyedropper).
  const ICON = {
    scroll: '<path d="M4 1.5h5l3.5 3.5v8.5a1 1 0 0 1-1 1h-7.5a1 1 0 0 1-1-1v-11a1 1 0 0 1 1-1z" fill="none" stroke="currentColor" stroke-width="1.3"/><path d="M8 6.5v5M5.8 9.4 8 11.6l2.2-2.2" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
    record: '<circle cx="8" cy="8" r="6.3" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="8" cy="8" r="3.4" fill="currentColor"/>',
    subject: '<rect x="1.6" y="2.6" width="12.8" height="10.8" rx="2" fill="none" stroke="currentColor" stroke-width="1.3"/><circle cx="8" cy="6.6" r="2" fill="currentColor"/><path d="M4.6 13.4c.5-2.2 1.8-3.3 3.4-3.3s2.9 1.1 3.4 3.3z" fill="currentColor"/>',
    colors: '<path d="M10.2 2.6a1.9 1.9 0 0 1 2.7 2.7l-1.4 1.4.6.6-1 1-.6-.6-4.7 4.7-2.3.6.6-2.3 4.7-4.7-.6-.6 1-1 .6.6z" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round"/>',
  };
  const cap = (t, cls = '') => `<span class="k${cls}">${t}</span>`;
  const btn = (title, keys, cls = '') => `<span class="bb${cls}">${title ? `<span class="t">${title}</span>` : ''}${keys.map(k => cap(k)).join('')}</span>`;
  const tool = (icon, key) => `<span class="bb sym tool" data-key="${key.toLowerCase()}"><svg viewBox="0 0 16 16" aria-hidden="true">${ICON[icon]}</svg>${cap(key)}</span>`;
  // The capture strip, after OverlayController+Chrome.swift captureStrip: Copy (primary), then the tools. Each tool here scrolls to
  // its feature card below; the eyedropper (U in the app) goes to the color card.
  const STRIP = `<span class="pill">${btn('Copy', ['&#8617;'], ' primary copy')}</span>`
    + `<span class="pill tools">${tool('scroll', 'G')}${tool('record', 'V')}${tool('subject', 'K')}${tool('colors', 'U')}</span>`;
  const CARD = { g: 'key-g', v: 'key-v', k: 'key-k', u: 'key-c' };

  const CURSOR = `
    <svg class="c-arrow" viewBox="-2 -2 17 24" width="17" height="24" aria-hidden="true"><path d="M0 0v16.4l3.9-3.7 2.6 6 2.9-1.2-2.6-5.9h5.4z" fill="#000" stroke="#fff" stroke-width="1.25" stroke-linejoin="round" paint-order="stroke"/></svg>
    <svg class="c-cross" viewBox="-11 -11 22 22" width="22" height="22" aria-hidden="true"><path d="M0-9.5v19M-9.5 0h19" stroke="#fff" stroke-width="3" stroke-linecap="square"/><path d="M0-8.75v17.5M-8.75 0h17.5" stroke="#000" stroke-width="1.1"/></svg>`;

  const size = r => `${Math.round(r.w)} x ${Math.round(r.h)}`;
  const inside = (r, p) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
  // The innermost element under the point; the bare desktop is the full screen.
  const hit = p => LIVE.filter(k => inside(BOX[k], p)).pop() || 'screen';
  const same = (a, b) => !!a && !!b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
  const keyOf = r => LIVE.find(k => same(BOX[k], r));
  // A rectangle's corner radii: the element's it lands on exactly, else square.
  const radiiFor = r => { const k = keyOf(r); return k ? BOX[k].radii : ZERO; };
  const firstChild = k => LIVE.find(c => BOX[c].p === k);
  // Snap: each edge of a dragged box moves to the nearest element edge within 10 px beside it.
  function snapRect(r) {
    const boxes = LIVE.map(k => BOX[k]);
    const to = (v, list) => { let best = v, d = 10.5; for (const c of list) if (Math.abs(c - v) < d) { d = Math.abs(c - v); best = c; } return best; };
    const xs = boxes.filter(b => b.y < r.y + r.h && b.y + b.h > r.y).flatMap(b => [b.x, b.x + b.w]);
    const ys = boxes.filter(b => b.x < r.x + r.w && b.x + b.w > r.x).flatMap(b => [b.y, b.y + b.h]);
    const x1 = to(r.x, xs), y1 = to(r.y, ys), x2 = to(r.x + r.w, xs), y2 = to(r.y + r.h, ys);
    return { x: x1, y: y1, w: Math.max(4, x2 - x1), h: Math.max(4, y2 - y1) };
  }

  /* The outline of `r` with per-corner radii, as OverlayView.path(_:radii:inset:outset:) builds it: a side on the screen's edge moves
     in by `inset`, every other side grows by `outset`, and a rounded corner grows with it. */
  function pathD(r, radii = ZERO, inset = 0, outset = 0) {
    const L = r.x <= 0.5, T = r.y <= 0.5, R = r.x + r.w >= W - 0.5, B = r.y + r.h >= H - 0.5;
    const x = r.x + (L ? inset : -outset), y = r.y + (T ? inset : -outset);
    const w = r.x + r.w - (R ? inset : -outset) - x, h = r.y + r.h - (B ? inset : -outset) - y;
    const m = Math.max(0, Math.min(w, h) / 2);
    const [tl, tr, br, bl] = radii.map(v => Math.min(m, v > 0 ? v + outset : 0));
    const f = n => Math.round(n * 100) / 100;
    return `M${f(x + tl)} ${f(y)}H${f(x + w - tr)}${tr ? `A${f(tr)} ${f(tr)} 0 0 1 ${f(x + w)} ${f(y + tr)}` : ''}V${f(y + h - br)}`
      + `${br ? `A${f(br)} ${f(br)} 0 0 1 ${f(x + w - br)} ${f(y + h)}` : ''}H${f(x + bl)}${bl ? `A${f(bl)} ${f(bl)} 0 0 1 ${f(x)} ${f(y + h - bl)}` : ''}`
      + `V${f(y + tl)}${tl ? `A${f(tl)} ${f(tl)} 0 0 1 ${f(x + tl)} ${f(y)}` : ''}Z`;
  }
  const FULL = `M0 0H${W}V${H}H0Z`;
  const lerpRect = (a, b, k) => ({ x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, w: a.w + (b.w - a.w) * k, h: a.h + (b.h - a.h) * k });
  const easeInOut = k => (k < .5 ? 2 * k * k : 1 - 2 * (1 - k) ** 2);
  const easeOutBack = k => 1 + 2.2 * (k - 1) ** 3 + 1.2 * (k - 1) ** 2;

  let uid = 0;

  class Demo {
    constructor(el) {
      this.el = el;
      this.gen = 0;
      this.mode = 'auto';
      const id = ++uid;
      this.deskLabel = 'Demo of the Snug overlay over two windows: a chat thread about rounding the avatars in a header, with a link to the change, and a code review of that change with an inline comment. Hover to select a message, the link preview, a diff line or the comment, or drag a box and pause to snap it. Return copies, Escape clears a selection, and G, V, K and U go to those features below.';
      el.innerHTML = `<div class="scene" data-open="true" data-cursor="cross">
        <div class="content">${CONTENT}</div>
        <svg class="ovg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" aria-hidden="true">
          <defs>
            <filter id="dg${id}" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter>
            <mask id="dm${id}" maskUnits="userSpaceOnUse" x="-64" y="-64" width="${W + 128}" height="${H + 128}">
              <rect x="-64" y="-64" width="${W + 128}" height="${H + 128}" fill="#fff"/><path class="m" fill="#000"/></mask>
          </defs>
          <path class="dim old" fill-rule="evenodd"/><path class="dim now" fill-rule="evenodd"/>
          <path class="hint"/><path class="ring"/>
          <g mask="url(#dm${id})"><path class="glow" filter="url(#dg${id})"/></g>
          <path class="hov"/><path class="ghost"/><path class="outl"/><path class="handles"/>
        </svg>
        <div class="ov">
          <div class="o-chip"></div><div class="o-snap" hidden></div><div class="o-strip">${STRIP}</div>
          <div class="o-toast"><span class="th"><span class="thc"></span></span><b>Copied</b><em></em></div>
          <div class="o-cursor">${CURSOR}</div>
        </div>
      </div>`;
      this.scene = el.querySelector('.scene');
      const q = s => this.scene.querySelector(s);
      this.g = {};
      for (const k of ['old', 'now', 'hint', 'ring', 'glow', 'hov', 'ghost', 'outl', 'handles']) this.g[k] = q(`.${k}`);
      this.g.mask = q('mask .m');
      this.g.blur = q('feGaussianBlur');
      Object.assign(this, { chip: q('.o-chip'), snapTag: q('.o-snap'), strip: q('.o-strip'), toast: q('.o-toast'), cursor: q('.o-cursor'), copyBtn: q('.o-strip .copy') });
      // The toast's thumbnail is the scene's own content, scaled and cropped to the copied area.
      this.thumb = q('.thc');
      this.thumb.appendChild(q('.content').cloneNode(true));
      this.s = { open: true, target: 'b1', drag: null, selr: null, path: [] };
      this.phone = false;
      this.ptr = { x: 480, y: 136 };
      this.chipKey = '';
      this.dimKey = null;
      new ResizeObserver(() => this.fit()).observe(el);
      this.setPhone(phoneQ.matches);
      phoneQ.addEventListener('change', () => { this.setPhone(phoneQ.matches); this.restart(); });
      this.bindUser();
      if (reduce) this.still();
      else {
        this.visible = true;
        new IntersectionObserver(([e]) => {
          this.visible = e.isIntersecting;
          if (this.mode === 'auto') { if (this.visible) this.play(); else this.halt(); }
        }).observe(el);
      }
    }

    /* Scale: the scene scales to the demo's width. The chrome keeps the app's point sizes relative to each other, at a size per scene
       px (--pt) that stays readable on a phone. */
    // Phone or desktop: the scene on show, the script, and whether the demo takes input at all.
    setPhone(on) {
      this.phone = on;
      this.cfg = on ? PHONE : DESK;
      this.view = this.cfg.view;
      LIVE = on ? KEYS.filter(k => !RV.includes(k)) : KEYS;
      const el = this.el;
      if (on) { el.removeAttribute('tabindex'); el.setAttribute('role', 'img'); }
      else { el.tabIndex = 0; el.setAttribute('role', 'group'); }
      el.setAttribute('aria-label', on
        ? 'Demo of the Snug overlay over a chat thread: it hovers a message and a link preview, drags a rough box around the link preview, which snaps to it, and copies it.'
        : this.deskLabel);
      this.fit();
    }
    // A change of layout (a rotation): start the right script from a clean overlay.
    restart() {
      clearTimeout(this.resumeT);
      this.gen++;
      this.grab = null;
      this.mode = 'auto';
      this.toast.classList.remove('show');
      this.reset();
      this.ptr = { x: 480, y: 136 };
      this.aim(this.ptr);
      this.s.target = hit(this.ptr);
      if (reduce) this.still();
      else if (this.visible) this.play();
      else this.render();
    }
    fit() {
      const v = this.view, k = this.el.clientWidth / v.w;
      if (!k) return;
      this.k = k;
      this.pt = this.phone ? 1.05 / k : Math.min(1.35, Math.max(0.72, 7.5 / (11 * k)));
      this.scene.style.transform = this.phone ? `scale(${k}) translate(${-v.x}px, ${-v.y}px)` : `scale(${k})`;
      this.scene.style.setProperty('--pt', this.pt);
      // The toast sits at the bottom centre of what is on show.
      this.scene.style.setProperty('--vx', `${v.x}px`);
      this.scene.style.setProperty('--tl', `${v.x + v.w / 2}px`);
      this.scene.style.setProperty('--tb', `${H - v.y - v.h}px`);
      this.g.blur.setAttribute('stdDeviation', (3.4 * this.pt).toFixed(2));
      // The tools group comes off when the strip would not fit the screen.
      this.strip.classList.remove('narrow');
      if (this.strip.offsetWidth > v.w - 16 * this.pt) this.strip.classList.add('narrow');
      this.stripSize = { w: this.strip.offsetWidth, h: this.strip.offsetHeight };
      this.chipKey = '';
      this.render();
    }

    aim(p) { this.ptr = p; this.cursor.style.transform = `translate(${p.x}px, ${p.y}px)`; }
    move(el, x, y) { el.style.transform = `translate(${Math.round(x * 2) / 2}px, ${Math.round(y * 2) / 2}px)`; }
    set(path, d) { if (path.getAttribute('d') !== d) path.setAttribute('d', d); }

    // The rectangle shown for the drag's snap: the tween toward it while it springs in.
    shownSnap() {
      const s = this.s, a = this.anim;
      if (!s.drag || !s.drag.snap) return null;
      if (!a) return s.drag.snap;
      const k = Math.min(1, (performance.now() - a.t0) / a.ms);
      if (k >= 1) { this.anim = null; return s.drag.snap; }
      return lerpRect(a.from, s.drag.snap, easeOutBack(k));
    }
    spring(from) {
      if (reduce) return this.render();
      const gen = this.gen;
      this.anim = { from, t0: performance.now(), ms: 170 };
      const step = () => { if (gen !== this.gen || !this.anim) return; this.render(); if (this.anim) requestAnimationFrame(step); };
      requestAnimationFrame(step);
    }

    render() {
      const s = this.s, g = this.g, P = this.pt;
      this.scene.dataset.open = String(s.open);
      if (!s.open) return;
      const hoverK = !s.drag && !s.selr ? s.target : null, hb = hoverK && BOX[hoverK];
      const ghost = s.drag ? s.drag.raw : null;
      const preview = this.shownSnap();
      const sel = s.selr;
      // The selection's (or the snap preview's) radii; a drag's raw box is square.
      const radii = sel ? radiiFor(sel) : s.drag && s.drag.snap ? radiiFor(s.drag.snap) : ZERO;

      // Dim: everything outside the target, nothing when it is the whole screen, nothing until a target resolves.
      const cut = sel || preview || ghost;
      let dim = '', dimKey;
      if (cut) { dim = same(cut, BOX.screen) ? '' : `${FULL}${pathD(cut, radii)}`; dimKey = 'drag'; }
      else if (hb) { dim = hoverK === 'screen' ? '' : `${FULL}${pathD(hb, hb.radii)}`; dimKey = hoverK; }
      else dimKey = null;
      // A new hover target crossfades the dim in 150 ms; a drag or selection changes it at once.
      if (!cut && this.dimKey && dimKey !== this.dimKey && !reduce && this.dimKey !== 'drag') {
        this.set(g.old, g.now.getAttribute('d') || '');
        g.old.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 150, easing: 'ease-out', fill: 'forwards' });
        g.now.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 150, easing: 'ease-out' });
      } else if (dimKey !== this.dimKey) this.set(g.old, '');
      this.dimKey = dimKey;
      this.set(g.now, dim);

      // The hover: a 1.5 pt line on the element's edge, a 3 pt ring just outside it, a soft glow outside, and a faint fill.
      // The whole screen gets no line, ring or glow: it would only trace the demo's frame.
      const lit = hb && hoverK !== 'screen' ? hb : null;
      this.set(g.hov, lit ? pathD(lit, lit.radii, 0.75 * P) : '');
      this.set(g.glow, lit ? pathD(lit, lit.radii) : '');
      this.set(g.mask, lit ? pathD(lit, lit.radii) : '');
      this.set(g.ring, lit ? pathD(lit, lit.radii, 3 * P, 2.25 * P) : '');
      // Faint dashed outlines of what Up and Down would pick: the parent (not the screen) and the first child.
      let hint = '';
      if (hb) {
        const up = hb.p && hb.p !== 'screen' ? hb.p : null, down = firstChild(hoverK);
        for (const k of [up, down]) if (k) hint += pathD(BOX[k], BOX[k].radii, 0.5 * P);
      }
      this.set(g.hint, hint);
      this.set(g.ghost, ghost ? pathD(ghost) : '');
      const box = sel || preview;
      this.set(g.outl, box ? pathD(box, radii, 0.75 * P) : '');
      let handles = '';
      if (sel) {
        const r = 4 * P;
        for (const [hx, hy] of [[0, 0], [.5, 0], [1, 0], [1, .5], [1, 1], [.5, 1], [0, 1], [0, .5]]) {
          const cx = sel.x + sel.w * hx, cy = sel.y + sel.h * hy;
          handles += `M${(cx - r).toFixed(2)} ${cy.toFixed(2)}a${r} ${r} 0 1 0 ${2 * r} 0a${r} ${r} 0 1 0 ${-2 * r} 0Z`;
        }
      }
      this.set(g.handles, handles);

      // The chip row: the hovered element's name and size; a drag's size and Snapped or Exact; a selection's size, then Snap.
      const cr = sel || preview || ghost || hb;
      let key = '', html = '';
      if (sel) { key = `s${size(sel)}`; html = `<span class="mono">${size(sel)}</span>`; }
      else if (s.drag) { const r = s.drag.snap || ghost; key = `d${size(r)}${!!s.drag.snap}`; html = `<span class="mono">${size(r)}&nbsp;&nbsp;${s.drag.snap ? 'Snapped' : 'Exact'}</span>`; }
      else if (hb) { key = `h${hoverK}`; html = `<b>${hb.n}</b><span class="mono dim2">${size(hb)}</span>`; }
      if (key !== this.chipKey) {
        this.chipKey = key;
        this.chip.innerHTML = html;
        this.snapTag.hidden = !sel;
        if (sel) this.snapTag.innerHTML = btn(sel.snapped ? 'Snapped' : 'Exact', ['S'], sel.snapped ? ' lit' : '');
        this.chipSize = { w: this.chip.offsetWidth, h: this.chip.offsetHeight, sw: sel ? this.snapTag.offsetWidth : 0 };
      }
      this.chip.hidden = !cr;
      this.strip.hidden = !(cr && !s.drag);
      if (cr) this.attach(sel ? sel : s.drag ? (s.drag.snap || ghost) : hb, !this.strip.hidden);
    }

    /* OverlayController+Chrome.swift attach(to:): the strip 8 pt below the box (above it with no room, else inside its bottom), from
       the box's left edge; the chip row 8 pt above the box (inside its top when the menu bar is in the way), from the left edge too. */
    attach(b, strip) {
      const P = this.pt, v = this.view, gap = 8 * P, top = MENU + gap, floor = v.y + v.h - gap;
      let over = b.y - gap;
      if (strip) {
        const { w, h } = this.stripSize;
        const below = b.y + b.h + gap, above = b.y - gap - h;
        let y, out = true;
        if (below + h <= floor) y = below;
        else if (above >= top) { y = above; over = y - 6 * P; }
        else { y = b.y + b.h - gap - h; out = false; }
        const x = Math.min(Math.max(b.x + (out ? 0 : gap), v.x + gap), v.x + v.w - w - gap);
        this.move(this.strip, x, y);
        // The strip and the gap between it and the box: a pointer crossing it keeps the hover, so the buttons can be reached.
        const lo = y >= b.y + b.h ? b.y + b.h : y, hi = y + h <= b.y ? b.y : y + h;
        this.reach = { x, y: lo, w, h: hi - lo };
      }
      const { w, h, sw } = this.chipSize, row = w + (sw ? 6 * P + sw : 0);
      let y = over - h, inset = 0;
      if (y < top) { y = b.y + gap; inset = gap; }
      const x = Math.min(Math.max(b.x + inset, v.x + gap), v.x + v.w - gap - row);
      this.move(this.chip, x, y);
      if (sw) this.move(this.snapTag, x + w + 6 * P, y);
    }

    // Return: the Copy button's cap presses, the overlay closes, and the toast shows what was copied.
    copy() {
      const s = this.s, r = s.selr || (s.target && BOX[s.target]);
      if (!s.open || !r) return;
      const gen = this.gen;
      this.copyBtn.classList.add('pressed');
      this.later(() => {
        this.copyBtn.classList.remove('pressed');
        const P = this.pt, tw = 44 * P, th = 28 * P, k = Math.max(tw / r.w, th / r.h);
        this.thumb.style.transform = `translate(${(tw - r.w * k) / 2 - r.x * k}px, ${(th - r.h * k) / 2 - r.y * k}px) scale(${k})`;
        // The detail is the image's size in pixels, twice the points on a Retina screen.
        this.toast.querySelector('em').textContent = `${Math.round(r.w) * 2} x ${Math.round(r.h) * 2}`;
        this.toast.classList.add('show');
        Object.assign(s, { open: false, selr: null, drag: null });
        this.closedAt = performance.now();
        this.scene.dataset.cursor = 'arrow';
        this.render();
        // As long as the app's default toast lifetime, 4 s. Like the app's, it stays up when the pointer moves on, so its timer belongs to
        // no run.
        clearTimeout(this.toastT);
        this.toastT = setTimeout(() => this.toast.classList.remove('show'), 4000);
      }, reduce ? 0 : 140, gen);
    }

    // A strip tool: its button lights for a moment, and the page scrolls to the tool's card and rings it.
    go(key) {
      const card = document.getElementById(CARD[key]);
      const b = this.strip.querySelector(`.tool[data-key="${key}"]`);
      if (b) { b.classList.add('lit'); clearTimeout(b.litT); b.litT = setTimeout(() => b.classList.remove('lit'), 220); }
      if (!card) return;
      card.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'center' });
      card.classList.remove('flash');
      void card.offsetWidth;
      card.classList.add('flash');
      clearTimeout(card.flashT);
      card.flashT = setTimeout(() => card.classList.remove('flash'), 2400);
    }

    // A timer owned by the current run: a takeover or a restart of the script cancels it.
    later(fn, ms, gen = this.gen) { setTimeout(() => { if (gen === this.gen) fn(); }, ms); }

    // Back to an open overlay with nothing dragged, selected or pressed. A toast stays until its own timer hides it.
    reset() {
      Object.assign(this.s, { open: true, drag: null, selr: null, path: [] });
      this.anim = null;
      this.copyBtn.classList.remove('pressed');
      this.scene.dataset.cursor = 'cross';
    }

    /* ---------- autoplay ---------- */
    halt() { this.gen++; }
    play() {
      clearTimeout(this.resumeT);
      const gen = ++this.gen;
      this.mode = 'auto';
      this.scene.dataset.auto = 'true';
      this.reset();
      const sleep = ms => new Promise((ok, no) => setTimeout(() => (gen === this.gen ? ok() : no(gen)), ms));
      const glide = (to, ms, each) => new Promise((ok, no) => {
        const a = { ...this.ptr }, t0 = performance.now();
        const step = now => {
          if (gen !== this.gen) return no(gen);
          const k = Math.min(1, (now - t0) / ms), e = easeInOut(k);
          this.aim({ x: a.x + (to.x - a.x) * e, y: a.y + (to.y - a.y) * e });
          each();
          this.render();
          k < 1 ? requestAnimationFrame(step) : ok();
        };
        requestAnimationFrame(step);
      });
      const hover = () => { this.s.target = hit(this.ptr); };
      // The overlay opening again after a copy fades in under the pointer instead of appearing at once.
      const reopen = () => {
        this.reset(); hover(); this.render();
        for (const e of [this.scene.querySelector('.ovg'), this.chip, this.strip]) e.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, easing: 'ease-out' });
      };
      const loop = async () => {
        let first = true;
        for (;;) {
          const s = this.s;
          if (first) { this.reset(); hover(); this.render(); first = false; } else reopen();
          // The pointer glides from wherever the last run left it, so a new loop never jumps. The desktop tour hovers a message
          // bubble, the link preview and a diff line; the phone's, the bubble and the link preview.
          const c = this.cfg;
          for (const [x, y, ms, hold] of c.tour) { await glide({ x, y }, ms, hover); await sleep(hold); }
          // Drag a loose box, pause, and it snaps to the card under it.
          await glide({ x: c.from[0], y: c.from[1] }, c.from[2], hover);
          await sleep(200);
          const start = { ...this.ptr };
          s.drag = { raw: { x: start.x, y: start.y, w: 0, h: 0 }, snap: null };
          await glide({ x: c.to[0], y: c.to[1] }, c.to[2], () => {
            s.drag.raw = { x: start.x, y: start.y, w: this.ptr.x - start.x, h: this.ptr.y - start.y };
          });
          await sleep(180);
          s.drag.snap = snapRect(s.drag.raw);
          this.spring(s.drag.raw);
          await sleep(1300);
          s.selr = { ...s.drag.snap, snapped: true }; s.drag = null; this.anim = null;
          await glide({ x: c.after[0], y: c.after[1] }, 500, () => {});
          await sleep(900);
          this.copy();
          await sleep(4600);
        }
      };
      loop().catch(g => { if (typeof g !== 'number') throw g; });
    }
    still() {
      const [fx, fy] = this.cfg.from, [tx, ty] = this.cfg.to;
      const raw = { x: fx, y: fy, w: tx - fx, h: ty - fy };
      Object.assign(this.s, { open: true, selr: null, drag: { raw, snap: snapRect(raw) } });
      this.scene.dataset.auto = 'false';
      this.render();
    }

    /* ---------- the visitor drives ---------- */
    // The visitor's first input stops the script and starts from a clean, open overlay.
    takeover() {
      clearTimeout(this.resumeT);
      if (this.mode === 'user') return;
      this.gen++;
      this.mode = 'user';
      this.scene.dataset.auto = 'false';
      this.reset();
    }
    resumeAfter(ms) {
      clearTimeout(this.resumeT);
      if (reduce) return;
      this.resumeT = setTimeout(() => { if (!this.grab && this.visible) this.play(); }, ms);
    }

    bindUser() {
      const el = this.el, s = this.s;
      const toScene = e => { const b = this.scene.getBoundingClientRect(); return { x: (e.clientX - b.left) / this.k, y: (e.clientY - b.top) / this.k }; };
      let snapT = 0;
      // The pointer is off the demo: nothing is hovered, and the script comes back.
      const away = ms => {
        if (this.mode !== 'user') return;
        if (!s.selr && !s.drag) { s.target = null; this.render(); }
        this.resumeAfter(ms);
      };
      // After a copy the overlay reopens on the next move, as pressing the shortcut again would.
      const reopen = p => {
        if (s.open || performance.now() - (this.closedAt || 0) < 500) return false;
        this.reset(); s.target = hit(p); this.render();
        return true;
      };
      const onStrip = e => !!e.target.closest && !!e.target.closest('.o-strip');
      // On a phone the demo only plays: no input reaches it (the stylesheet also gives it no pointer events).
      const on = (type, fn) => el.addEventListener(type, e => { if (!this.phone) fn(e); });
      on('pointerenter', e => { if (e.pointerType === 'mouse') this.over = true; });
      on('pointermove', e => {
        // A mouse over the demo takes over; touch only takes over with a press.
        if (e.pointerType !== 'mouse' && !this.grab) return;
        this.takeover();
        // Over the strip the target holds still, so its buttons stay under the pointer.
        if (!this.grab && onStrip(e)) return;
        const p = toScene(e);
        this.ptr = p;
        if (!s.open) { reopen(p); return; }
        const g = this.grab;
        if (!g) {
          if (!s.selr && !(this.reach && !this.strip.hidden && inside(this.reach, p))) { s.target = hit(p); this.render(); }
          return;
        }
        if (!g.moved && Math.hypot(p.x - g.start.x, p.y - g.start.y) < 4) return;
        g.moved = true; s.selr = null;
        const raw = { x: Math.min(g.start.x, p.x), y: Math.min(g.start.y, p.y), w: Math.abs(p.x - g.start.x), h: Math.abs(p.y - g.start.y) };
        const keep = !e.altKey && s.drag && s.drag.snap && same(snapRect(raw), s.drag.snap);
        s.drag = { raw, snap: keep ? s.drag.snap : null };
        if (!keep) this.anim = null;
        clearTimeout(snapT);
        // A short rest previews the snap, as in the app; Option keeps the box exact.
        if (!keep && !e.altKey) snapT = setTimeout(() => {
          if (!s.drag || !this.grab) return;
          const sn = snapRect(s.drag.raw);
          s.drag.snap = same(sn, s.drag.raw) ? null : sn;
          if (s.drag.snap) this.spring(s.drag.raw); else this.render();
        }, 80);
        this.render();
      });
      on('pointerleave', e => {
        if (e.pointerType === 'mouse') this.over = false;
        if (!this.grab) away(e.pointerType === 'mouse' ? LEAVE_MS : TOUCH_IDLE_MS);
      });
      on('pointerdown', e => {
        if (e.button !== 0) return;
        this.takeover();
        if (e.pointerType === 'mouse') e.preventDefault();
        // A pointer focus is marked so the stylesheet draws no ring for it.
        el.dataset.via = 'pointer';
        el.focus({ preventScroll: true });
        // The strip's buttons act on click, below.
        if (onStrip(e)) return;
        const p = toScene(e);
        this.ptr = p;
        if (!s.open) { if (!reopen(p)) { this.reset(); s.target = hit(p); this.render(); } return; }
        if (!s.selr) { s.target = hit(p); this.render(); }
        this.grab = { start: p, moved: false };
        try { el.setPointerCapture(e.pointerId); } catch { /* a pointer the browser no longer tracks */ }
      });
      on('pointerup', e => {
        const g = this.grab;
        if (!g) return;
        this.grab = null;
        clearTimeout(snapT);
        if (g.moved && s.drag) {
          const snapped = !!s.drag.snap && !e.altKey;
          s.selr = { ...(snapped ? s.drag.snap : s.drag.raw), snapped }; s.drag = null; this.anim = null;
        } else if (s.selr && !inside(s.selr, this.ptr)) { s.selr = null; s.target = hit(this.ptr); }
        else this.copy();
        this.render();
        const b = el.getBoundingClientRect();
        const out = e.clientX < b.left || e.clientX > b.right || e.clientY < b.top || e.clientY > b.bottom;
        if (e.pointerType !== 'mouse') away(TOUCH_IDLE_MS);
        else if (out) away(LEAVE_MS);
      });
      on('pointercancel', () => {
        this.grab = null; clearTimeout(snapT);
        s.drag = null; this.anim = null;
        away(TOUCH_IDLE_MS);
        this.render();
      });
      this.strip.addEventListener('click', e => {
        if (this.phone) return;
        const b = e.target.closest('.bb');
        if (!b) return;
        if (b === this.copyBtn) this.copy();
        else if (b.dataset.key) this.go(b.dataset.key);
      });
      /* Keys act only while the demo is focused, or while the pointer is over it and nothing else on the page has focus, so the
         page's own keys are left alone. Arrows need focus, so hovering never takes over page scrolling. */
      document.addEventListener('keydown', e => {
        if (this.phone || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
        const focused = document.activeElement === el;
        const idle = !document.activeElement || document.activeElement === document.body;
        if (!focused && !(this.over && idle)) return;
        const key = e.key.length === 1 ? e.key.toLowerCase() : e.key;
        if (CARD[key]) { e.preventDefault(); this.go(key); return; }
        if (!['Enter', 'Escape'].concat(focused ? ['ArrowUp', 'ArrowDown'] : []).includes(e.key)) return;
        e.preventDefault();
        this.takeover();
        this.resumeAfter(TOUCH_IDLE_MS * 2);
        if (!s.open) { if (e.key === 'Enter') { this.reset(); s.target = s.target || 'ch'; this.render(); } return; }
        if (e.key === 'Enter') this.copy();
        // Esc drops a selection back to hovering what is under the pointer, else closes the overlay (OverlayController keyDown).
        else if (e.key === 'Escape') {
          if (s.selr) { s.selr = null; s.target = hit(this.ptr); }
          else { s.open = false; this.closedAt = performance.now(); }
        }
        else if (e.key === 'ArrowUp' && !s.selr && s.target && BOX[s.target].p) { s.path.push(s.target); s.target = BOX[s.target].p; }
        else if (e.key === 'ArrowDown' && !s.selr && s.path.length) s.target = s.path.pop();
        this.render();
      });
      el.addEventListener('blur', () => {
        if (this.phone) return;
        delete el.dataset.via;
        if (this.mode === 'user' && !el.matches(':hover')) this.resumeAfter(LEAVE_MS);
      });
    }
  }

  for (const el of document.querySelectorAll('.demo')) new Demo(el);

  /* ---------- the header shortcut: a cap lights while its key (or a pointer on it) is down, and the ⌃⇧Space chord flashes all three ---------- */
  const caps = document.querySelector('.caps.hk');
  if (caps) {
    const cap = {};
    for (const b of caps.querySelectorAll('[data-k]')) cap[b.dataset.k] = b;
    caps.addEventListener('animationend', e => { if (e.target === caps) caps.classList.remove('chord'); });
    const real = { ctrl: false, shift: false, space: false };
    // A pointer press holds its cap down while the pointer is down, and for at least a short beat so a quick tap still shows.
    const tap = { ctrl: 0, shift: 0, space: 0 };
    const MIN_TAP_MS = 140;
    const paint = () => { for (const k in cap) cap[k].classList.toggle('down', real[k] || !!tap[k]); };
    const fire = () => {
      for (const c of Object.values(cap)) c.classList.add('flash');
      // The chord also pops the group: a bounce and one ring (CSS .chord, 500 ms). Restarting it drops the class, reflows, and adds it again.
      // The flash lets go as the bounce settles; with reduced motion there is no pop and the flash is the whole effect.
      if (!reduce) { caps.classList.remove('chord'); void caps.offsetWidth; caps.classList.add('chord'); }
      clearTimeout(fire.t);
      fire.t = setTimeout(() => { for (const c of Object.values(cap)) c.classList.remove('flash'); }, reduce ? 450 : 320);
    };
    const name = e => e.key === 'Control' ? 'ctrl' : e.key === 'Shift' ? 'shift' : (e.code === 'Space' || e.key === ' ') ? 'space' : '';
    addEventListener('keydown', e => {
      const k = name(e);
      if (!k) return;
      real[k] = true;
      paint();
      if (k === 'space' && e.ctrlKey && e.shiftKey) {
        e.preventDefault();
        if (!e.repeat) fire();
      }
    });
    addEventListener('keyup', e => { const k = name(e); if (k) { real[k] = false; paint(); } });
    addEventListener('blur', () => { real.ctrl = real.shift = real.space = false; paint(); });
    let held = null;
    const release = () => {
      if (!held) return;
      const { k, t0 } = held;
      held = null;
      setTimeout(() => { tap[k] = 0; paint(); }, Math.max(0, MIN_TAP_MS - (performance.now() - t0)));
    };
    caps.addEventListener('pointerdown', e => {
      const b = e.target.closest('[data-k]');
      if (!b || e.button !== 0) return;
      e.preventDefault();
      release();
      held = { k: b.dataset.k, t0: performance.now() };
      tap[held.k] = 1;
      paint();
    });
    for (const t of ['pointerup', 'pointercancel', 'pointerleave']) caps.addEventListener(t, release);
  }
})();
