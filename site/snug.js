'use strict';
// Snug site: the main demo is a drawing of a Mac with the Snug overlay open. It plays itself until the visitor moves
// the pointer over it, taps it or presses a key; then it is live. Coordinates are the mock screen's own (unscaled)
// CSS pixels; the screen element is scaled to fit, so every client rect is divided by `scale`.
(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const R = Math.round;
  const clamp = (v, a, b) => Math.min(Math.max(v, a), b);
  const $ = s => document.querySelector(s);

  const stage = $('.stage'), screen = $('.screen'), scene = $('.scene'), ov = $('.ov');
  const [hl, dimall, hintUp, hintDown, ghost, selEl, flashEl, sizeChip, strip] =
    ['.hl', '.dimall', '.hint.up', '.hint.down', '.ghost', '.sel', '.flash', '.chip.size', '.strip'].map(s => ov.querySelector(s));
  const cast = $('.cast'), cursor = $('.cursor'), toastEl = $('.toast'), statusEl = $('.status'), agentRef = $('.ag-ref');
  const row = scene.querySelector('[data-n="Lookout Ridge"]'), card = scene.querySelector('[data-n="Conditions"]');

  let W = 1000, H = 625, scale = 1;
  let open = true, meta = false;
  let target = row;                           // an element, 'desk' (the wallpaper), or the screen itself
  let hold = null, path = [];                 // a key-picked target holds until the pointer leaves it
  let sel = null, drag = null, grab = null, ptr = null;
  let snapT = 0, glideT = 0, closeT = 0, toastT = 0, castT = 0;

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
    if (!el || !scene.contains(el)) return undefined;
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
    if (!open || sel || drag || grab || !ptr) return;
    if (!strip.hidden) {
      const b = box(strip);
      if (inside({ x: b.x, y: b.y - 10, w: b.w, h: b.h + 10 }, ptr)) return;
    }
    if (hold) {
      const within = target instanceof Element && target !== screen && inside(box(target), ptr) && inside(box(target), hold);
      if (Math.hypot(ptr.x - hold.x, ptr.y - hold.y) < 30 || within) return;
      hold = null;
    }
    const t = hitAt(ptr);
    if (t !== undefined && t !== target) { target = t; path = []; }
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
    if (!reduce) {
      ov.classList.add('glide');
      clearTimeout(glideT);
      glideT = setTimeout(() => ov.classList.remove('glide'), 120);
    }
    say(`${target.dataset.n}, ${size(box(target))}`);
  }
  function beep() {
    sizeChip.classList.remove('shake');
    void sizeChip.offsetWidth;
    sizeChip.classList.add('shake');
    say('Nothing further that way.');
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

  // The reference line Snug puts on the clipboard next to the image for an agent.
  const ID = '0123456789ABCDEFGHJKMNPQRSTVWXYZ', TITLED = ['row', 'button', 'link', 'folder', 'file', 'menu bar item', 'image'];
  function reference(el, r, name) {
    const id = Array.from({ length: 8 }, () => ID[Math.floor(Math.random() * 32)]).join('');
    const win = el && el !== screen ? el.closest('.win') : null;
    const role = el && el !== screen ? el.dataset.role : null;
    const title = role === 'window' ? win.dataset.title : TITLED.includes(role) ? name : null;
    const what = (role || name).toLowerCase() + (title ? ` "${title}"` : '');
    return `[Snug capture ${id}: ${win ? `${win.dataset.app}, ` : ''}${what}, ${size(r)} pt. Use the snug MCP tool get_capture to see it.]`;
  }

  function toast(title, detail, r) {
    toastEl.querySelector('b').textContent = title;
    toastEl.querySelector('.t-text span').textContent = detail;
    const a = r.w / r.h, th = toastEl.querySelector('i');
    th.style.width = `${Math.max(4, a >= 1 ? 40 : 40 * a)}px`;
    th.style.height = `${Math.max(4, a >= 1 ? 40 / a : 40)}px`;
    toastEl.classList.add('show');
    clearTimeout(toastT);
    toastT = setTimeout(() => toastEl.classList.remove('show'), 2600);
  }

  function copy(agent) {
    const { el, r, name } = current();
    place(flashEl, r);
    flashEl.classList.remove('go');
    void flashEl.offsetWidth;
    flashEl.classList.add('go');
    if (agent) {
      agentRef.textContent = reference(el, r, name);
      agentRef.closest('.ag').classList.add('live');
      toast('Copied for agent', 'Paste it into the chat. The agent sees what you saw.', r);
    } else toast('Copied', `${name}, ${size(r)}`, r);
    say(`Copied ${name}, ${size(r)}${agent ? ', for an agent' : ''}.`);
    closeT = setTimeout(closeOverlay, reduce ? 0 : 260);
  }
  function closeOverlay() {
    open = false; sel = null; drag = null; grab = null; hold = null;
    render();
  }
  function openOverlay() {
    open = true;
    hover();
    render();
  }

  // The keys the demo knows. Returns whether it acted.
  const GLYPH = { ArrowUp: '\u2191', ArrowDown: '\u2193', ArrowLeft: '\u2190', ArrowRight: '\u2192', Enter: '\u21A9', Escape: 'esc' };
  function act(k, mods = {}) {
    if (!open || !GLYPH[k]) return false;
    if (k === 'Enter') copy(!!mods.metaKey);
    else if (k === 'Escape') {
      if (sel || drag) { sel = null; drag = null; grab = null; hover(); } else closeOverlay();
    } else if (!sel && !drag) walk(k);
    else return false;
    render();
    // Name the key next to the pointer, where the eye is.
    if (ptr) {
      cast.textContent = (mods.metaKey ? '\u2318' : '') + GLYPH[k];
      at(cast, clamp(ptr.x + 16, 4, W - 60), clamp(ptr.y + 24, 4, H - 40));
      cast.classList.remove('out');
      clearTimeout(castT);
      castT = setTimeout(() => cast.classList.add('out'), 700);
    }
    return true;
  }

  /* ---------- pointer: shared by the visitor and the autoplay ---------- */
  function down(p, touch) {
    ptr = p;
    if (!open) return openOverlay();
    grab = { tap: touch, start: p, moved: false, edges: edges() };
  }
  function move(p, alt) {
    ptr = p;
    if (grab) dragMove(alt); else hover();
    render();
  }
  function dragMove(alt) {
    const dx = ptr.x - grab.start.x, dy = ptr.y - grab.start.y;
    if (!grab.moved && Math.hypot(dx, dy) < 4) return;
    grab.moved = true;
    if (grab.tap) return;
    sel = null;
    const rect = { x: Math.min(grab.start.x, ptr.x), y: Math.min(grab.start.y, ptr.y), w: Math.abs(dx), h: Math.abs(dy) };
    const keep = !alt && drag && drag.snap && near(snapRect(rect, grab.edges), drag.snap, 0);
    drag = { rect, snap: keep ? drag.snap : null };
    clearTimeout(snapT);
    // Pause to snap: the preview shows after a short rest. Option keeps the area exact.
    if (!keep && !alt) {
      snapT = setTimeout(() => {
        if (!drag || !grab) return;
        const s = snapRect(drag.rect, grab.edges);
        drag.snap = near(s, drag.rect, .5) ? null : s;
        render();
      }, 80);
    }
  }
  function up(alt) {
    if (!grab) return;
    const g = grab;
    grab = null;
    clearTimeout(snapT);
    if (g.tap) {
      if (!g.moved) tap();
    } else if (drag) {
      const r = drag.snap && !alt ? drag.snap : drag.rect;
      sel = { x: r.x, y: r.y, w: Math.max(4, r.w), h: Math.max(4, r.h), snapped: r === drag.snap };
      sel.el = match(sel);
      drag = null;
      say(`Area ${size(sel)}, ${sel.snapped ? 'snapped' : 'exact'}. Return copies it.`);
    } else if (sel && !inside(sel, ptr)) { sel = null; hover(); }
    else copy(false);
    render();
  }
  // Touch: a tap frames an element, a second tap on it copies it.
  function tap() {
    const t = hitAt(ptr);
    if (t === undefined) return;
    if (t === target) return copy(false);
    target = t; path = []; hold = { ...ptr };
  }

  // A pointer resting over the demo at load is not a takeover, and neither is a touch that scrolls the page:
  // while it plays, only a real move of the mouse, or a touch that lifts where it landed, hands it over.
  let first = null, touchAt = null;
  screen.addEventListener('pointermove', e => {
    if (playing && e.pointerType === 'touch') return;
    first = first || { x: e.clientX, y: e.clientY };
    if (playing && Math.hypot(e.clientX - first.x, e.clientY - first.y) < 4) return;
    stop();
    move(toBase(e), e.altKey);
  });
  screen.addEventListener('pointerdown', e => {
    if (playing && e.pointerType === 'touch') { touchAt = { x: e.clientX, y: e.clientY }; return; }
    stop();
    if (e.button !== 0 || e.target.closest('button')) return;
    e.preventDefault();
    stage.focus({ preventScroll: true });
    down(toBase(e), e.pointerType === 'touch');
    if (grab && !grab.tap) screen.setPointerCapture(e.pointerId);
  });
  screen.addEventListener('pointerup', e => {
    if (!touchAt) return up(e.altKey);
    const near10 = Math.hypot(e.clientX - touchAt.x, e.clientY - touchAt.y) < 10;
    touchAt = null;
    if (near10 && !e.target.closest('button')) { stop(); ptr = toBase(e); tap(); render(); }
  });
  screen.addEventListener('pointercancel', () => { touchAt = null; grab = null; drag = null; render(); });
  strip.addEventListener('click', () => { stop(); copy(meta); render(); });

  document.addEventListener('keydown', e => {
    stop();
    if (e.target.closest('a')) return;
    if (e.key === 'Meta') { meta = true; render(); return; }
    if (e.ctrlKey && e.shiftKey && e.code === 'Space') { e.preventDefault(); if (!open) openOverlay(); return; }
    if (!e.ctrlKey && act(e.key, e)) e.preventDefault();
  });
  document.addEventListener('keyup', e => { if (e.key === 'Meta') { meta = false; render(); } });
  addEventListener('blur', () => { meta = false; render(); });

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

  function render() {
    screen.dataset.mode = open ? 'capture' : 'closed';
    ov.classList.toggle('cmd', meta);
    if (!open) return;
    const t = !sel && !drag && target instanceof Element ? target : null;
    const tb = t && box(t);
    const r = drag ? drag.snap || drag.rect : sel || tb;

    dimall.hidden = !(!sel && !drag && target === 'desk');
    place(hl, tb);
    if (t) { hl.classList.toggle('full', t === screen); hl.style.borderRadius = `${t.dataset.r || 0}px`; }

    // Faint outlines show what Up and Down would pick.
    const upEl = t && t !== screen ? t.parentElement.closest('[data-n]') : null;
    const ub = upEl && upEl !== screen ? box(upEl) : null;
    place(hintUp, ub && !near(ub, tb, 4) ? ub : null);
    const db = t && path.length ? box(path[path.length - 1]) : null;
    place(hintDown, db && !near(db, tb, 4) ? db : null);
    for (const [h, b] of [[hintUp, ub], [hintDown, db]]) h.classList.toggle('small', !!b && (b.w < 48 || b.h < 24));

    place(selEl, r && (drag || sel) ? r : null);
    place(ghost, drag && drag.snap ? drag.rect : null);

    // Size chip above the object, or inside it when there is no room.
    const tag = on => `<span class="tag${on ? ' lit' : ''}">${on ? 'Snapped' : 'Exact'}</span>`;
    sizeChip.innerHTML = drag ? `${size(r)} ${tag(drag.snap)}` : sel ? `${size(sel)} ${tag(sel.snapped)}`
      : tb ? `<b>${t.dataset.n}</b><span class="muted">${size(tb)}</span>` : '';
    sizeChip.hidden = !r;
    if (r) {
      const y = r.y - sizeChip.offsetHeight - 8;
      at(sizeChip, clamp(r.x, 4, W - sizeChip.offsetWidth - 4), y < 4 ? r.y + 8 : y);
    }

    // The Copy button under the object, or inside its bottom edge when there is no room.
    strip.hidden = !(!drag && (sel || tb));
    if (!strip.hidden) {
      strip.querySelector('.lab').textContent = meta ? 'Agent' : 'Copy';
      const sw = strip.offsetWidth, sh = strip.offsetHeight;
      let y = r.y + r.h + 8;
      if (y + sh > H - 4) y = Math.min(r.y + r.h, H) - sh - 8;
      at(strip, clamp(r.x + r.w / 2 - sw / 2, 4, W - sw - 4), y);
    }
  }

  function fit() {
    screen.classList.toggle('narrow', stage.clientWidth < 600);
    W = screen.offsetWidth;
    H = screen.offsetHeight;
    const top = stage.getBoundingClientRect().top + scrollY;
    scale = Math.min(1.08, stage.clientWidth / W, (innerHeight - top - 48) / H);
    screen.style.transform = `scale(${scale})`;
    screen.style.left = `${(stage.clientWidth - W * scale) / 2}px`;
    stage.style.height = `${H * scale}px`;
    render();
  }

  /* ---------- autoplay: hover, Up, Up, a drag that snaps, Return; then again ---------- */
  let playing = !reduce, playT = 0, raf = 0, cur = { x: 0, y: 0 };
  const pt = (el, fx, fy, dx = 0, dy = 0) => { const b = box(el); return { x: R(b.x + b.w * fx + dx), y: R(b.y + b.h * fy + dy) }; };
  const aim = p => { cur = p; cursor.style.transform = `translate(${p.x}px, ${p.y}px)`; };
  // Move the drawn cursor, acting as the pointer on every frame.
  function glideTo(p, ms) {
    const a = cur, t0 = performance.now();
    const step = now => {
      const k = Math.min(1, (now - t0) / ms), e = k < .5 ? 2 * k * k : 1 - 2 * (1 - k) ** 2;
      aim({ x: R(a.x + (p.x - a.x) * e), y: R(a.y + (p.y - a.y) * e) });
      move(cur);
      if (k < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
  }
  // Each step runs, then waits its time. The drag starts 4 px off the card's corner and ends 5 px past the other.
  const SCRIPT = [
    [() => { open = true; sel = null; path = []; hold = null; target = row; aim(pt(row, .5, .5)); ptr = cur; render(); }, 1300],
    [() => act('ArrowUp'), 1000],
    [() => act('ArrowUp'), 1100],
    [() => glideTo(pt(card, 0, 0, -4, -4), 700), 850],
    [() => down(cur), 120],
    [() => glideTo(pt(card, 1, 1, 5, 4), 900), 1200],
    [() => up(), 800],
    [() => act('Enter'), 2000],
    [() => { ptr = cur; openOverlay(); glideTo(pt(row, .5, .5), 800); }, 1000],
  ];
  function play(i) {
    SCRIPT[i][0]();
    playT = setTimeout(() => play((i + 1) % SCRIPT.length), SCRIPT[i][1]);
  }
  function stop() {
    if (!playing) return;
    playing = false;
    for (const t of [playT, snapT, closeT, castT]) clearTimeout(t);
    cancelAnimationFrame(raf);
    cursor.hidden = true;
    cast.hidden = true;
    open = true; grab = null; drag = null; sel = null; hold = null; ptr = null;
    render();
  }

  addEventListener('resize', fit);
  fit();
  agentRef.textContent = reference(row, box(row), row.dataset.n);
  if (playing) { cursor.hidden = false; play(0); } else render();
})();
