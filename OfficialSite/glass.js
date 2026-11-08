/* Liquid glass for the web.
   Technique from the open-source web liquid-glass projects (e.g. deepika-builds/liquid-glass,
   archisvaze/liquid-glass): a per-element displacement map that is neutral in the middle and
   bends the backdrop near the rounded edge, applied through an SVG backdrop-filter. Three
   slightly different scales, one per colour channel, give the faint prism fringe on the rim.
   Refraction needs Chromium; Safari and Firefox get a frosted blur with the same tint and
   highlights from CSS. */
(function () {
  const NS = "http://www.w3.org/2000/svg";
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const refracts = brands.some((b) => /Chromium|Google Chrome|Microsoft Edge/.test(b.brand)) ||
    (/Chrome\/\d+/.test(navigator.userAgent) && !/Firefox|FxiOS/.test(navigator.userAgent));
  let defs = null, seq = 0;
  const maps = new Map();

  function ensureDefs() {
    if (defs) return defs;
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("aria-hidden", "true");
    svg.style.cssText = "position:absolute;width:0;height:0;overflow:hidden;pointer-events:none";
    defs = document.createElementNS(NS, "defs");
    svg.appendChild(defs);
    document.body.appendChild(svg);
    return defs;
  }

  // Signed distance to a rounded rectangle centred at the origin; negative inside.
  function sdf(px, py, hw, hh, r) {
    const qx = Math.abs(px) - (hw - r), qy = Math.abs(py) - (hh - r);
    const ox = Math.max(qx, 0), oy = Math.max(qy, 0);
    return Math.hypot(ox, oy) + Math.min(Math.max(qx, qy), 0) - r;
  }

  function makeMap(w, h, r, band) {
    const key = `${w}x${h}r${r}b${band}`;
    if (maps.has(key)) return maps.get(key);
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    const ctx = c.getContext("2d");
    const img = ctx.createImageData(w, h), d = img.data;
    const hw = w / 2, hh = h / 2, e = 0.75;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const px = x + 0.5 - hw, py = y + 0.5 - hh;
        const dist = -sdf(px, py, hw, hh, r);
        let R = 128, B = 128;
        if (dist < band) {
          // Outward normal from the SDF gradient.
          let nx = sdf(px + e, py, hw, hh, r) - sdf(px - e, py, hw, hh, r);
          let ny = sdf(px, py + e, hw, hh, r) - sdf(px, py - e, hw, hh, r);
          const len = Math.hypot(nx, ny) || 1;
          nx /= len; ny /= len;
          const t = 1 - Math.max(0, dist) / band;
          const k = t * t * (3 - 2 * t); // smoothstep: strongest at the rim
          R = 128 + nx * k * 127;
          B = 128 + ny * k * 127;
        }
        const i = (y * w + x) * 4;
        d[i] = R; d[i + 1] = 128; d[i + 2] = B; d[i + 3] = 255;
      }
    }
    ctx.putImageData(img, 0, 0);
    const url = c.toDataURL();
    maps.set(key, url);
    return url;
  }

  function build(el, o) {
    const w = Math.max(2, Math.round(el.offsetWidth)), h = Math.max(2, Math.round(el.offsetHeight));
    if (w > 900 || h > 900) return null;
    const cs = getComputedStyle(el);
    const r = Math.min(parseFloat(cs.borderTopLeftRadius) || 0, w / 2, h / 2);
    const band = o.band || Math.min(18, Math.max(6, Math.min(w, h) * 0.32));
    const url = makeMap(w, h, r, band);
    const id = el.dataset.glassId || "lg" + (++seq);
    el.dataset.glassId = id;
    let f = document.getElementById(id);
    if (!f) { f = document.createElementNS(NS, "filter"); f.id = id; ensureDefs().appendChild(f); }
    const s = o.scale;
    f.setAttribute("x", "0"); f.setAttribute("y", "0");
    f.setAttribute("width", w); f.setAttribute("height", h);
    f.setAttribute("filterUnits", "userSpaceOnUse");
    f.setAttribute("primitiveUnits", "userSpaceOnUse");
    f.setAttribute("color-interpolation-filters", "sRGB");
    f.innerHTML = `
      <feImage href="${url}" x="0" y="0" width="${w}" height="${h}" preserveAspectRatio="none" result="map"/>
      <feDisplacementMap in="SourceGraphic" in2="map" scale="${s}" xChannelSelector="R" yChannelSelector="B" result="dR"/>
      <feColorMatrix in="dR" type="matrix" values="1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0" result="r"/>
      <feDisplacementMap in="SourceGraphic" in2="map" scale="${s * 1.05}" xChannelSelector="R" yChannelSelector="B" result="dG"/>
      <feColorMatrix in="dG" type="matrix" values="0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0" result="g"/>
      <feDisplacementMap in="SourceGraphic" in2="map" scale="${s * 1.1}" xChannelSelector="R" yChannelSelector="B" result="dB"/>
      <feColorMatrix in="dB" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0" result="b"/>
      <feBlend in="r" in2="g" mode="screen" result="rg"/>
      <feBlend in="rg" in2="b" mode="screen"/>`;
    return id;
  }

  const observed = new WeakSet();
  const ro = typeof ResizeObserver !== "undefined" ? new ResizeObserver((entries) => entries.forEach((e) => refresh(e.target))) : null;

  function refresh(el) {
    const o = el._glass;
    if (!o) return;
    const id = refracts ? build(el, o) : null;
    const tail = `blur(${o.blur}px) saturate(${o.saturate})`;
    el.style.backdropFilter = id ? `url(#${id}) ${tail}` : `blur(${o.fallbackBlur}px) saturate(${o.saturate})`;
    el.style.webkitBackdropFilter = `blur(${o.fallbackBlur}px) saturate(${o.saturate})`;
  }

  function apply(el, opts = {}) {
    if (!el) return;
    el._glass = Object.assign({ scale: -28, blur: 2, saturate: 1.8, fallbackBlur: 14 }, opts);
    el.classList.add("lg");
    refresh(el);
    if (ro && !observed.has(el)) { observed.add(el); ro.observe(el); }
  }

  window.NousGlass = { apply, refresh, refracts };
})();
