(function () {
  const root = document.documentElement;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // Start the entrance once the serif font is ready (or after a short timeout) so the
  // wordmark never swaps fonts mid-animation.
  let started = false;
  const start = () => {
    if (started) return;
    started = true;
    requestAnimationFrame(() => {
      document.body.classList.add("is-ready");
      if (window.NousDemo) window.NousDemo.boot(reduce ? 0 : 1500);
    });
  };
  if (document.fonts && document.fonts.load) {
    document.fonts.load('48px "Instrument Serif"').then(start, start);
    setTimeout(start, 700);
  } else start();

  // Background follows the pointer very slightly.
  if (!reduce) {
    const field = document.querySelector(".bg-col");
    let tx = 0, ty = 0, x = 0, y = 0, raf = 0;
    const loop = () => {
      x += (tx - x) * 0.04; y += (ty - y) * 0.04;
      field.style.setProperty("--mx", x.toFixed(3));
      field.style.setProperty("--my", y.toFixed(3));
      raf = Math.abs(tx - x) + Math.abs(ty - y) > 0.001 ? requestAnimationFrame(loop) : 0;
    };
    window.addEventListener("pointermove", (e) => {
      tx = e.clientX / window.innerWidth - 0.5;
      ty = e.clientY / window.innerHeight - 0.5;
      if (!raf) raf = requestAnimationFrame(loop);
    }, { passive: true });
  }

  document.getElementById("try").addEventListener("click", (e) => {
    const b = e.target.closest("[data-run]");
    if (b && window.NousDemo) window.NousDemo.run(b.dataset.run);
  });
})();
