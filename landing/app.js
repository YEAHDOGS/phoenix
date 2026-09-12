// Phoenix landing: panel reveals, parallax bg drift, sticky CTA, notify form.
// Notify form is front-end only for now (no backend yet). Motion: transform/opacity only.
(function () {
  'use strict';
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var scroller = document.getElementById('panels');
  var panels = Array.prototype.slice.call(document.querySelectorAll('.panel'));

  // Staggered clip reveals on panel entry — root is the snap container.
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); }
      });
    }, { root: scroller, threshold: 0.35 });
    panels.forEach(function (p) { io.observe(p); });
  } else {
    panels.forEach(function (p) { p.classList.add('in'); });
  }

  // Parallax bg drift: translate only, rAF-throttled, paused offscreen.
  if (!reduced && scroller) {
    var imgs = Array.prototype.slice.call(document.querySelectorAll('.panel .bg img'));
    var ticking = false;
    function drift() {
      ticking = false;
      var vh = window.innerHeight;
      imgs.forEach(function (img) {
        var r = img.closest('.panel').getBoundingClientRect();
        if (r.bottom < -vh || r.top > 2 * vh) return; // offscreen: skip
        var dy = r.top + r.height / 2 - vh / 2;
        img.style.transform = 'translate3d(0,' + (-8 - dy * 0.10).toFixed(1) + '%,0) scale(1.04)';
      });
    }
    scroller.addEventListener('scroll', function () {
      if (!ticking) { ticking = true; requestAnimationFrame(drift); }
    }, { passive: true });
    drift();
  }

  // Sticky mobile CTA: hide when hero CTA or hatch panel is in view.
  var sticky = document.querySelector('.sticky-cta');
  if (sticky && 'IntersectionObserver' in window) {
    var hideCount = 0;
    function setSticky(hide) {
      hideCount = Math.max(0, hideCount + (hide ? 1 : -1));
      sticky.style.display = hideCount > 0 ? 'none' : '';
    }
    var so = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) { setSticky(en.isIntersecting); });
    }, { root: scroller });
    var heroCta = document.querySelector('.hero .cta-row');
    var hatch = document.getElementById('p-hatch');
    if (heroCta) so.observe(heroCta);
    if (hatch) so.observe(hatch);
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
    try { localStorage.setItem('phoenix-notify', value); } catch (err) {}
    setTimeout(function () { window.location.href = './thanks.html'; }, 800);
  });
})();
