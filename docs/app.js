// Axolotl marketing site interactions.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Nav background once the page scrolls.
  const nav = document.getElementById('nav');
  const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  // Reveal on scroll.
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  document.querySelectorAll('.reveal').forEach((el, i) => {
    el.style.transitionDelay = `${Math.min(i % 4, 3) * 70}ms`;
    io.observe(el);
  });

  // Themes mirror App/Shared/Theme.swift.
  const themes = {
    'axolotl':        { name: 'Axolotl', dark: false, bg: '#FFFFFF', sidebar: '#F7F4F6', text: '#2F2B33', secondary: '#9A929D', accent: '#E14F78', heading: '#1E1A22', code: '#C2386A', codebg: '#F6F2F4', highlight: '#FFEAA6', link: '#D9466F', quote: '#7C7380' },
    'axolotl-night':  { name: 'Axolotl Night', dark: true, bg: '#1C1620', sidebar: '#151018', text: '#E7DFEA', secondary: '#8A7E8F', accent: '#FF7A9C', heading: '#FFFFFF', code: '#FFA3BA', codebg: '#271E2B', highlight: '#5E4320', link: '#FF8FAD', quote: '#A396A8' },
    'red-graphite':   { name: 'Red Graphite', dark: false, bg: '#FFFFFF', sidebar: '#F4F4F4', text: '#404040', secondary: '#9C9C9C', accent: '#DD4C4F', heading: '#2F2F2F', code: '#D0484B', codebg: '#F5F5F5', highlight: '#FFF09A', link: '#DD4C4F', quote: '#7A7A7A' },
    'dracula':        { name: 'Dracula', dark: true, bg: '#282A36', sidebar: '#21222C', text: '#F8F8F2', secondary: '#6272A4', accent: '#FF79C6', heading: '#BD93F9', code: '#50FA7B', codebg: '#343746', highlight: '#6A5E2A', link: '#8BE9FD', quote: '#9EA8C7' },
    'nord':           { name: 'Nord', dark: true, bg: '#2E3440', sidebar: '#272C36', text: '#D8DEE9', secondary: '#6B7589', accent: '#88C0D0', heading: '#ECEFF4', code: '#A3BE8C', codebg: '#3B4252', highlight: '#5E5A3A', link: '#81A1C1', quote: '#9AA5B8' },
    'solarized-light':{ name: 'Solarized', dark: false, bg: '#FDF6E3', sidebar: '#EEE8D5', text: '#586E75', secondary: '#93A1A1', accent: '#CB4B16', heading: '#073642', code: '#D33682', codebg: '#EEE8D5', highlight: '#F5E3A1', link: '#268BD2', quote: '#839496' },
    'tokyo-night':    { name: 'Tokyo Night', dark: true, bg: '#1A1B26', sidebar: '#16161E', text: '#C0CAF5', secondary: '#565F89', accent: '#7AA2F7', heading: '#BB9AF7', code: '#9ECE6A', codebg: '#24283B', highlight: '#4F4A2A', link: '#7DCFFF', quote: '#8189AF' },
    'rose-pine-dawn': { name: 'Rosé Pine Dawn', dark: false, bg: '#FAF4ED', sidebar: '#F2E9E1', text: '#575279', secondary: '#9893A5', accent: '#D7827E', heading: '#907AA9', code: '#B4637A', codebg: '#F2E9E1', highlight: '#F6E1B5', link: '#286983', quote: '#797593' },
  };
  const more = [
    ['#FFFFFF', '#C8102E'], ['#1A1A1A', '#F0A04B'], ['#002B36', '#CB4B16'], ['#282828', '#FE8019'],
    ['#EFF1F5', '#8839EF'], ['#1E1E2E', '#CBA6F7'], ['#2D353B', '#A7C080'], ['#191724', '#EBBCBA'], ['#232325', '#E5605F'],
  ];

  const mock = document.getElementById('mock');
  function applyTheme(id) {
    const t = themes[id];
    if (!t || !mock) return;
    const s = mock.style;
    s.setProperty('--m-bg', t.bg); s.setProperty('--m-sidebar', t.sidebar); s.setProperty('--m-text', t.text);
    s.setProperty('--m-secondary', t.secondary); s.setProperty('--m-accent', t.accent); s.setProperty('--m-heading', t.heading);
    s.setProperty('--m-code', t.code); s.setProperty('--m-codebg', t.codebg); s.setProperty('--m-highlight', t.highlight);
    s.setProperty('--m-link', t.link); s.setProperty('--m-quote', t.quote);
    mock.dataset.dark = t.dark;
    picker.querySelectorAll('.swatch').forEach((b) => b.setAttribute('aria-pressed', b.dataset.theme === id));
  }
  const picker = document.querySelector('.theme-picker');
  for (const [id, t] of Object.entries(themes)) {
    const b = document.createElement('button');
    b.className = 'swatch';
    b.dataset.theme = id;
    b.type = 'button';
    b.innerHTML = `<i style="background: linear-gradient(135deg, ${t.bg} 50%, ${t.accent} 50%)"></i>${t.name}`;
    b.addEventListener('click', () => applyTheme(id));
    picker.appendChild(b);
  }
  applyTheme(window.matchMedia('(prefers-color-scheme: dark)').matches ? 'axolotl-night' : 'axolotl');

  // Theme swatches tile.
  const sw = document.getElementById('swatches');
  if (sw) {
    const all = Object.values(themes).map((t) => [t.bg, t.accent]).concat(more).slice(0, 12);
    for (const [bg, accent] of all) {
      const i = document.createElement('i');
      i.style.background = bg;
      i.style.setProperty('--d', accent);
      sw.appendChild(i);
    }
  }

  // Markdown editing / reading demo.
  const md = document.getElementById('md-demo');
  if (md) {
    const tabs = md.querySelectorAll('.mode span');
    let reading = false;
    const set = (r) => {
      reading = r;
      md.classList.toggle('reading', r);
      tabs.forEach((t) => t.classList.toggle('on', (t.dataset.mode === 'read') === r));
    };
    tabs.forEach((t) => t.addEventListener('click', () => { set(t.dataset.mode === 'read'); clearInterval(timer); }));
    const timer = reduce ? null : setInterval(() => set(!reading), 2800);
  }

  // Search demo: types queries and shows matching notes.
  const qEl = document.getElementById('search-q');
  const rEl = document.getElementById('search-results');
  const searches = [
    { q: '#work @todo', results: [['Atlas Q3 Roadmap', '2 open todos · #work/atlas'], ['Hiring plan', '4 open todos · #work/hiring'], ['Weekly sync', '1 open todo · #work']] },
    { q: '"pastel de nata"', results: [['Lisbon in October', 'Pastéis de nata at Manteigaria'], ['Receipt, Café do Monte', 'Found in image · #travel/portugal']] },
    { q: '@images @last7days', results: [['Lisbon in October', '3 images · Yesterday'], ['Whiteboard sketches', '2 images · Tuesday'], ['Moodboard', '8 images · Sunday']] },
    { q: 'ramen -#archive', results: [['Weeknight Miso Ramen', 'Serves 2 · 25 minutes · #recipes'], ['Tokyo food list', 'Ramen spots near Shinjuku · #travel']] },
  ];
  const highlight = (s) => s.replace(/(@\w+|#[\w/]+|-#?\w+|"[^"]*")/g, '<span class="op">$1</span>');
  const renderResults = (list) => {
    rEl.innerHTML = list.map(([t, d], i) =>
      `<div class="res" style="animation-delay:${i * 70}ms"><svg><use href="#i-doc"/></svg><div><b>${t}</b><span>${d}</span></div></div>`).join('');
  };
  if (qEl && rEl) {
    if (reduce) {
      qEl.innerHTML = highlight(searches[0].q);
      renderResults(searches[0].results);
    } else {
      let idx = 0;
      const run = async () => {
        const { q, results } = searches[idx % searches.length];
        rEl.innerHTML = '';
        for (let i = 1; i <= q.length; i++) {
          qEl.innerHTML = highlight(q.slice(0, i));
          await new Promise((r) => setTimeout(r, 55 + Math.random() * 45));
        }
        renderResults(results);
        await new Promise((r) => setTimeout(r, 2600));
        for (let i = q.length; i >= 0; i--) {
          qEl.innerHTML = highlight(q.slice(0, i));
          await new Promise((r) => setTimeout(r, 18));
        }
        idx++;
        run();
      };
      const sio = new IntersectionObserver((e) => { if (e[0].isIntersecting) { sio.disconnect(); run(); } });
      sio.observe(qEl);
    }
  }

  // Copy buttons.
  document.querySelectorAll('.copy-btn').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const text = btn.parentElement.firstChild.textContent.trim();
      try { await navigator.clipboard.writeText(text); } catch { return; }
      btn.innerHTML = '<svg><use href="#i-check"/></svg>';
      setTimeout(() => { btn.innerHTML = '<svg><use href="#i-copy"/></svg>'; }, 1400);
    });
  });

  // Latest release label.
  fetch('https://api.github.com/repos/nearbycoder/axolotl/releases/latest')
    .then((r) => (r.ok ? r.json() : null))
    .then((r) => {
      if (!r || !r.tag_name) return;
      const el = document.getElementById('release-label');
      if (el) el.textContent = `Version ${r.tag_name.replace(/^v/, '')} · Live Markdown and a fresh new look`;
    })
    .catch(() => {});
})();
