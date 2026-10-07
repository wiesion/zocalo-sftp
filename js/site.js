/* zocalo-sftp site.js — progressive enhancement only.
   Every feature degrades gracefully without JS:
   - copy buttons are hidden (CSS .no-js)
   - tabs render as a stacked sequence
   - theme falls back to prefers-color-scheme
*/
(function () {
  'use strict';

  /* ---------- Copy to clipboard ---------- */
  function copyText(text, onDone) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        onDone(true);
      }, function () {
        fallbackCopy(text, onDone);
      });
    } else {
      fallbackCopy(text, onDone);
    }
  }

  function fallbackCopy(text, onDone) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'absolute';
    ta.style.left = '-9999px';
    document.body.appendChild(ta);
    ta.select();
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    onDone(ok);
  }

  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    var status = btn.parentElement.querySelector('.copy-status');
    if (!status) {
      status = document.createElement('span');
      status.className = 'copy-status';
      status.setAttribute('aria-live', 'polite');
      btn.parentElement.appendChild(status);
    }
    btn.addEventListener('click', function () {
      var text = btn.getAttribute('data-copy');
      if (!text && btn.hasAttribute('data-copy-sibling')) {
        var pre = btn.parentElement.querySelector('pre');
        text = pre ? pre.innerText : '';
      }
      if (!text) return;
      copyText(text, function (ok) {
        btn.classList.toggle('done', ok);
        btn.textContent = ok ? 'copied ✓' : 'copy failed';
        status.textContent = ok ? 'Copied to clipboard' : 'Copy failed';
        setTimeout(function () {
          btn.classList.remove('done');
          btn.textContent = 'copy';
          status.textContent = '';
        }, 2000);
      });
    });
  });

  /* ---------- Tabs ---------- */
  document.querySelectorAll('.js-tabs').forEach(function (root) {
    var tabs = Array.prototype.slice.call(root.querySelectorAll('[role="tab"]'));
    var panels = Array.prototype.slice.call(root.querySelectorAll('[role="tabpanel"]'));
    if (tabs.length < 2) return;

    function select(tab, focus) {
      tabs.forEach(function (t) {
        var sel = t === tab;
        t.setAttribute('aria-selected', sel ? 'true' : 'false');
        t.tabIndex = sel ? 0 : -1;
      });
      panels.forEach(function (p) {
        p.classList.toggle('active', p.id === tab.getAttribute('aria-controls'));
      });
      if (focus) tab.focus();
    }

    tabs.forEach(function (tab, i) {
      tab.addEventListener('click', function () { select(tab, false); });
      tab.addEventListener('keydown', function (e) {
        var next = null;
        if (e.key === 'ArrowRight') next = tabs[(i + 1) % tabs.length];
        else if (e.key === 'ArrowLeft') next = tabs[(i - 1 + tabs.length) % tabs.length];
        else if (e.key === 'Home') next = tabs[0];
        else if (e.key === 'End') next = tabs[tabs.length - 1];
        if (next) { e.preventDefault(); select(next, true); }
      });
    });
  });

  /* ---------- Theme toggle ----------
     Default: follow prefers-color-scheme (CSS handles it).
     Toggle: sets data-theme, persists in localStorage.
     No flash: a tiny inline script in <head> reads localStorage before paint. */
  var toggle = document.querySelector('.js-theme-toggle');
  if (toggle) {
    function currentTheme() {
      var attr = document.documentElement.getAttribute('data-theme');
      if (attr === 'light' || attr === 'dark') return attr;
      return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    }
    toggle.addEventListener('click', function () {
      var next = currentTheme() === 'dark' ? 'light' : 'dark';
      document.documentElement.setAttribute('data-theme', next);
      try { localStorage.setItem('zocalo-theme', next); } catch (e) { /* private mode */ }
    });
  }
})();
