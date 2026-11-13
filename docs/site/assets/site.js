// Screenshots animate in when they scroll into view (skipped with prefers-reduced-motion).
(function () {
  var items = document.querySelectorAll('.reveal');
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var v = document.querySelector('video');
  if (v) {
    v.addEventListener('mouseenter', function () { v.controls = true; });
    v.addEventListener('mouseleave', function () { v.controls = false; });
  }
  if (reduce || !('IntersectionObserver' in window)) {
    items.forEach(function (el) { el.classList.add('in'); });
    if (reduce && v) { v.removeAttribute('autoplay'); v.pause(); v.controls = true; }
    return;
  }
  document.documentElement.classList.add('js');
  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (e) {
      if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    });
  }, { threshold: 0.18 });
  items.forEach(function (el) { io.observe(el); });
})();
