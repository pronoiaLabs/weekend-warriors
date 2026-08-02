/* FIX-PLAN behaviour. Inlined into FIX-PLAN.html by tools/build_plan.py.
   Vanilla, no external requests: the file is normally opened over file://.
   PLAN_INDEX and PLAN_TOTAL are emitted just above this by the generator. */
(function () {
  'use strict';

  var TASK_KEY = 'fixplan.tasks';
  var THEME_KEY = 'fixplan.theme';

  var sections = [].slice.call(document.querySelectorAll('.section'));
  var rows = [].slice.call(document.querySelectorAll('.navrow'));
  var items = [].slice.call(document.querySelectorAll('.navitem'));
  var boxes = [].slice.call(document.querySelectorAll('.tbox'));
  var searchEl = document.getElementById('search');
  var hintEl = document.getElementById('hint');
  var current = null;

  function store(key) {
    try {
      return JSON.parse(localStorage.getItem(key) || '{}');
    } catch (e) {
      return {};
    }
  }
  function save(key, val) {
    try {
      localStorage.setItem(key, JSON.stringify(val));
    } catch (e) {
      /* private mode, or file:// with storage blocked. Progress just will not persist. */
    }
  }

  /* ------------------------------------------------------------------ theme */

  var themeBtn = document.getElementById('theme');
  var THEMES = ['system', 'light', 'dark'];
  var GLYPH = { system: '◐', light: '☀', dark: '☾' };

  function applyTheme(mode) {
    if (mode === 'system') {
      document.documentElement.removeAttribute('data-theme');
    } else {
      document.documentElement.setAttribute('data-theme', mode);
    }
    themeBtn.textContent = GLYPH[mode];
    themeBtn.title = 'Theme: ' + mode;
  }
  var theme = localStorage.getItem(THEME_KEY);
  if (THEMES.indexOf(theme) < 0) theme = 'system';
  applyTheme(theme);
  themeBtn.addEventListener('click', function () {
    theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
    try {
      localStorage.setItem(THEME_KEY, theme);
    } catch (e) {}
    applyTheme(theme);
  });

  /* -------------------------------------------------------------- checkboxes */

  // A saved value applies only when the task's signature still matches. If the
  // wording changed in FIX-PLAN.md, the .md value wins rather than showing stale
  // state after a regenerate.
  function restore() {
    var saved = store(TASK_KEY);
    boxes.forEach(function (box) {
      var rec = saved[box.id];
      if (rec && rec.s === box.dataset.sig) box.checked = !!rec.c;
    });
  }

  function persist() {
    var out = {};
    boxes.forEach(function (box) {
      out[box.id] = { c: box.checked, s: box.dataset.sig };
    });
    save(TASK_KEY, out);
  }

  function counts() {
    var done = 0;
    var perSection = {};
    boxes.forEach(function (box) {
      var id = box.closest('.section').id;
      if (!perSection[id]) perSection[id] = { n: 0, d: 0 };
      perSection[id].n++;
      if (box.checked) {
        perSection[id].d++;
        done++;
      }
    });

    var pct = PLAN_TOTAL ? Math.round((done / PLAN_TOTAL) * 100) : 0;
    document.getElementById('progtext').textContent =
      done + ' of ' + PLAN_TOTAL + ' done · ' + pct + '%';
    document.getElementById('barfill').style.width = pct + '%';

    var perGroup = {};
    rows.forEach(function (row) {
      var id = row.dataset.leaf;
      var c = perSection[id] || { n: 0, d: 0 };
      var dot = row.querySelector('.dot');
      dot.className = 'dot ' + (c.n === 0 ? 'none' : c.d === c.n ? 'done' : '');
      dot.title = c.n === 0 ? 'no tasks' : c.d + ' of ' + c.n + ' done';

      var head = row.closest('.navgroup').querySelector('.groupcount');
      if (head) {
        var g = head.dataset.group;
        if (!perGroup[g]) perGroup[g] = { n: 0, d: 0 };
        perGroup[g].n += c.n;
        perGroup[g].d += c.d;
      }

      var label = document.querySelector('[data-count="' + id + '"]');
      if (label) label.textContent = c.d + ' of ' + c.n + ' checked';
    });

    [].forEach.call(document.querySelectorAll('.groupcount'), function (el) {
      var g = perGroup[el.dataset.group];
      el.textContent = g && g.n ? g.d + '/' + g.n : '';
    });
  }

  document.addEventListener('change', function (e) {
    if (!e.target.classList.contains('tbox')) return;
    persist();
    counts();
  });

  document.getElementById('reset').addEventListener('click', function () {
    try {
      localStorage.removeItem(TASK_KEY);
    } catch (e) {}
    location.reload();
  });

  /* -------------------------------------------------------------- navigation */

  function show(id, subId) {
    var target = document.getElementById(id);
    if (!target || !target.classList.contains('section')) {
      target = sections[0];
      id = target.id;
    }
    if (current !== id) {
      sections.forEach(function (s) {
        s.classList.toggle('active', s.id === id);
      });
      items.forEach(function (b) {
        b.classList.toggle('active', b.dataset.target === id);
      });
      rows.forEach(function (r) {
        r.classList.toggle('open', r.dataset.leaf === id);
      });
      current = id;
      observe();
      var row = document.querySelector('.navrow[data-leaf="' + id + '"]');
      if (row && row.scrollIntoView) row.scrollIntoView({ block: 'nearest' });
    }
    var anchor = subId && document.getElementById(subId);
    if (anchor) {
      anchor.scrollIntoView({ block: 'start' });
    } else {
      window.scrollTo(0, 0);
    }
  }

  // A hash is either a section id, or a subsection id which starts with its
  // section id followed by "-".
  function route() {
    var h = (location.hash || '').replace(/^#/, '');
    if (!h) return show(sections[0].id, null);
    if (document.getElementById(h) && document.getElementById(h).classList.contains('section')) {
      return show(h, null);
    }
    var el = document.getElementById(h);
    if (el) {
      var sec = el.closest('.section');
      if (sec) return show(sec.id, h);
    }
    show(sections[0].id, null);
  }

  document.addEventListener('click', function (e) {
    var nav = e.target.closest('.navitem');
    if (nav) {
      if (location.hash === '#' + nav.dataset.target) route();
      else location.hash = '#' + nav.dataset.target;
    }
  });

  /* --------------------------------------------------------------- scroll-spy */

  var spy = null;
  function observe() {
    if (spy) spy.disconnect();
    var sec = document.getElementById(current);
    var heads = [].slice.call(sec.querySelectorAll('h3.sub'));
    if (!heads.length || !window.IntersectionObserver) return;

    spy = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (en) {
          if (!en.isIntersecting) return;
          [].forEach.call(document.querySelectorAll('.subitem.here'), function (a) {
            a.classList.remove('here');
          });
          var link = document.querySelector('.subitem[data-sub="' + en.target.id + '"]');
          if (link) {
            link.classList.add('here');
            link.scrollIntoView({ block: 'nearest' });
          }
        });
      },
      { rootMargin: '0px 0px -72% 0px', threshold: 0 }
    );
    heads.forEach(function (h) {
      spy.observe(h);
    });
  }

  /* -------------------------------------------------------------------- copy */

  document.addEventListener('click', function (e) {
    var btn = e.target.closest('.copy');
    if (!btn) return;
    // Copies the block verbatim, diff markers included: stripping them would
    // silently change what you paste.
    var text = btn.parentNode.querySelector('pre').textContent;
    var done = function () {
      btn.textContent = 'Copied';
      btn.classList.add('ok');
      setTimeout(function () {
        btn.textContent = 'Copy';
        btn.classList.remove('ok');
      }, 1200);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else {
      fallback();
    }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try {
        document.execCommand('copy');
        done();
      } catch (err) {
        btn.textContent = 'Failed';
      }
      document.body.removeChild(ta);
    }
  });

  /* ------------------------------------------------------------------ search */

  // Sections are display:none, so browser find cannot span the document. The
  // build-time index covers every panel, code included.
  var MARKED = [];

  function clearMarks() {
    MARKED.forEach(function (m) {
      var p = m.parentNode;
      if (!p) return;
      p.replaceChild(document.createTextNode(m.textContent), m);
      p.normalize();
    });
    MARKED = [];
  }

  function markHits(sec, needle) {
    clearMarks();
    if (!needle) return;
    var walker = document.createTreeWalker(sec, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue.toLowerCase().includes(needle)) return NodeFilter.FILTER_REJECT;
        if (node.parentNode.closest('mark')) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var targets = [];
    while (walker.nextNode()) targets.push(walker.currentNode);

    targets.forEach(function (node) {
      var lower = node.nodeValue.toLowerCase();
      var at = lower.indexOf(needle);
      var node2 = node;
      while (at >= 0) {
        var after = node2.splitText(at);
        var rest = after.splitText(needle.length);
        var mark = document.createElement('mark');
        after.parentNode.replaceChild(mark, after);
        mark.appendChild(after);
        MARKED.push(mark);
        node2 = rest;
        lower = node2.nodeValue.toLowerCase();
        at = lower.indexOf(needle);
      }
    });

    if (MARKED.length) MARKED[0].scrollIntoView({ block: 'center' });
  }

  function filter() {
    var q = searchEl.value.trim().toLowerCase();
    if (!q) {
      rows.forEach(function (r) {
        r.classList.remove('hide');
      });
      [].forEach.call(document.querySelectorAll('.navgroup'), function (g) {
        g.classList.remove('hide');
      });
      hintEl.textContent = '';
      clearMarks();
      return;
    }

    var total = 0;
    var hits = {};
    PLAN_INDEX.forEach(function (entry) {
      var n = 0;
      var at = entry.text.indexOf(q);
      while (at >= 0) {
        n++;
        at = entry.text.indexOf(q, at + q.length);
      }
      if (n) {
        hits[entry.id] = n;
        total += n;
      }
    });

    rows.forEach(function (r) {
      r.classList.toggle('hide', !hits[r.dataset.leaf]);
    });
    [].forEach.call(document.querySelectorAll('.navgroup'), function (g) {
      var any = [].slice.call(g.querySelectorAll('.navrow')).some(function (r) {
        return !r.classList.contains('hide');
      });
      g.classList.toggle('hide', !any);
    });

    var n = Object.keys(hits).length;
    hintEl.textContent = total
      ? total + ' hit' + (total === 1 ? '' : 's') + ' in ' + n + ' section' + (n === 1 ? '' : 's')
      : 'no matches';

    if (hits[current]) {
      markHits(document.getElementById(current), q);
    } else {
      clearMarks();
    }
  }

  searchEl.addEventListener('input', filter);
  searchEl.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') {
      searchEl.value = '';
      filter();
      searchEl.blur();
      return;
    }
    if (e.key !== 'Enter') return;
    // Jump to the first still-visible section that matched.
    var first = rows.filter(function (r) {
      return !r.classList.contains('hide');
    })[0];
    if (first) location.hash = '#' + first.dataset.leaf;
  });

  document.addEventListener('keydown', function (e) {
    if (e.key === '/' && document.activeElement !== searchEl) {
      e.preventDefault();
      searchEl.focus();
      searchEl.select();
    }
  });

  /* -------------------------------------------------------------------- init */

  window.addEventListener('hashchange', function () {
    route();
    if (searchEl.value.trim()) filter();
  });

  restore();
  counts();
  route();
  document.querySelector('.hint').textContent = '';
})();
