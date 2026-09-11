// Phoenix landing: ember canvas, scroll reveals, sticky CTA, notify form.
// Notify form is front-end only for now (no backend yet).
(function () {
  'use strict';
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Rising embers: one lightweight canvas, transform-free particle drift
  // (positions updated in JS, drawn with fillRect/arcs — no layout thrash).
  var canvas = document.getElementById('embers');
  if (canvas && !reduced) {
    var ctx = canvas.getContext('2d');
    var parts = [];
    var W = 0, H = 0, running = true, raf = 0;

    function resize() {
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = canvas.clientWidth; H = canvas.clientHeight;
      canvas.width = W * dpr; canvas.height = H * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    function spawn(seed) {
      var r = Math.random;
      parts.push({
        x: r() * W,
        y: seed ? r() * H : H + 10,
        s: 0.6 + r() * 2.2,          // size
        v: 0.25 + r() * 0.9,         // rise speed
        drift: (r() - 0.5) * 0.4,    // horizontal sway
        life: 0,
        max: 320 + r() * 260,
        hue: 14 + r() * 22           // ember orange range
      });
    }

    function tick() {
      if (!running) return;
      ctx.clearRect(0, 0, W, H);
      for (var i = parts.length - 1; i >= 0; i--) {
        var p = parts[i];
        p.life++;
        p.y -= p.v;
        p.x += p.drift + Math.sin(p.life * 0.02) * 0.3;
        var fade = 1 - p.life / p.max;
        if (fade <= 0 || p.y < -12) { parts.splice(i, 1); spawn(false); continue; }
        ctx.beginPath();
        ctx.arc(p.x, p.y, p.s * fade + 0.4, 0, 6.2832);
        ctx.fillStyle = 'hsla(' + p.hue + ', 88%, 55%, ' + (0.55 * fade).toFixed(3) + ')';
        ctx.fill();
      }
      raf = requestAnimationFrame(tick);
    }

    resize();
    window.addEventListener('resize', resize);
    var count = Math.min(70, Math.floor(window.innerWidth / 8));
    for (var i = 0; i < count; i++) spawn(true);

    // Pause when the hero is offscreen — one canvas, zero waste.
    if ('IntersectionObserver' in window) {
      new IntersectionObserver(function (entries) {
        var vis = entries[0].isIntersecting;
        if (vis && !running) { running = true; tick(); }
        else if (!vis && running) { running = false; cancelAnimationFrame(raf); }
      }).observe(canvas);
    }
    tick();
  }

  // Scroll reveals: opacity + transform only, never blocking input.
  var revealEls = document.querySelectorAll('.reveal');
  if (revealEls.length && 'IntersectionObserver' in window && !reduced) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); }
      });
    }, { threshold: 0.18, rootMargin: '0px 0px -8% 0px' });
    revealEls.forEach(function (el) { io.observe(el); });
  } else {
    revealEls.forEach(function (el) { el.classList.add('in'); });
  }

  // Sticky mobile CTA: hide when hero CTA or notify section is in view.
  var sticky = document.querySelector('.sticky-cta');
  if (sticky && 'IntersectionObserver' in window) {
    var heroCta = document.querySelector('.hero .cta-row');
    var notify = document.getElementById('notify');
    var hideCount = 0;
    function setSticky(hide) {
      hideCount += hide ? 1 : -1;
      if (hideCount < 0) hideCount = 0;
      sticky.style.display = hideCount > 0 ? 'none' : '';
    }
    var so = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { setSticky(en.isIntersecting); });
    });
    if (heroCta) so.observe(heroCta);
    if (notify) so.observe(notify);
  }

  // Notify form: validate, brief loading state, then thanks page.
  var form = document.querySelector('form[data-notify]');
  if (!form) return;
  var email = form.querySelector('input[type="email"]');
  var error = form.querySelector('.field-error');
  var button = form.querySelector('button');

  function setError(msg) {
    error.textContent = msg;
    email.setAttribute('aria-invalid', msg ? 'true' : 'false');
    if (msg) email.focus();
  }

  email.addEventListener('input', function () { setError(''); });

  form.addEventListener('submit', function (e) {
    e.preventDefault();
    var value = email.value.trim();
    if (!value) { setError('Please enter your email address.'); return; }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
      setError('That does not look like an email address.');
      return;
    }
    setError('');
    button.disabled = true;
    button.classList.add('loading');
    setTimeout(function () { window.location.href = './thanks.html'; }, 800);
  });
})();
