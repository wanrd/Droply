(() => {
  const clamp = (val, min = 0, max = 1) => Math.min(max, Math.max(min, val));
  const lerp = (start, end, t) => start + (end - start) * t;
  const smootherstep = (x) => x * x * x * (x * (x * 6 - 15) + 10);

  const elements = {
    heroSection: document.getElementById('hero'),
    heroColorCanvas: document.getElementById('heroColorCanvas'),
    heroCenterpiece: document.getElementById('heroCenterpiece'),
    heroWordmark: document.getElementById('heroWordmark'),
    heroBottomBar: document.getElementById('heroBottomBar'),
    bridgeCard: document.getElementById('interactiveBridgeCard'),
    bridgeCanvas: document.getElementById('bridgeCanvas'),
    marqueeLeft: document.getElementById('marqueeLeft'),
    marqueeRight: document.getElementById('marqueeRight'),
    footerMonument: document.getElementById('footerMonument'),
    footerWordmark: document.getElementById('footerWordmark')
  };

  let currentScroll = window.scrollY;
  let smoothScroll = currentScroll;
  let lastFrameTime = performance.now();

  const revealObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-revealed');
          revealObserver.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.14 }
  );
  document.querySelectorAll('[data-reveal]').forEach((el) => revealObserver.observe(el));

  document.querySelectorAll('[data-spotlight]').forEach((row) => {
    row.addEventListener('pointermove', (e) => {
      const rect = row.getBoundingClientRect();
      row.style.setProperty('--mx', `${e.clientX - rect.left}px`);
      row.style.setProperty('--my', `${e.clientY - rect.top}px`);
    });
  });

  // =========================================================
  // BLOCK 01: ARCHITECTURAL HERO SCROLL RESPONSE
  // =========================================================
  function updateHeroStage(scrollY) {
    if (!elements.heroSection) return;
    const total = Math.max(1, elements.heroSection.offsetHeight * 0.75);
    const p = clamp(scrollY / total, 0, 1);
    const ease = smootherstep(p);

    if (elements.heroCenterpiece) {
      elements.heroCenterpiece.style.transform = `translate3d(0, ${lerp(0, -28, ease).toFixed(1)}px, 0)`;
      elements.heroCenterpiece.style.opacity = `${clamp(1 - ease * 0.72, 0.28, 1).toFixed(3)}`;
    }

    if (elements.heroWordmark) {
      elements.heroWordmark.style.letterSpacing = `${lerp(-0.04, 0.04, ease).toFixed(3)}em`;
    }

    if (elements.heroBottomBar) {
      elements.heroBottomBar.style.transform = `translate3d(0, ${lerp(0, -18, ease).toFixed(1)}px, 0)`;
      elements.heroBottomBar.style.opacity = `${clamp(1 - ease * 0.9, 0.1, 1).toFixed(3)}`;
    }
  }

  // =========================================================
  // HERO LIVELY BLUE & WHITE WANDERING LUMINOUS FIELD
  // =========================================================
  const heroColorField = (() => {
    const canvas = elements.heroColorCanvas;
    const section = elements.heroSection;
    if (!canvas || !section) return null;

    const ctx = canvas.getContext('2d');
    if (!ctx) return null;

    let width = 0;
    let height = 0;
    const look = { x: 0, y: 0, tx: 0, ty: 0 };

    // Shades of blue + luminous ice/white orbs with broad Gaussian diffusion
    const orbs = [
      {
        fx: 0.44,
        fy: 0.34,
        px: 0.3,
        py: 1.1,
        pulseFreq: 1.35,
        radiusFactor: 0.56,
        rgb: [22, 92, 255], // deep cobalt blue
        alpha: 0.48
      },
      {
        fx: 0.36,
        fy: 0.48,
        px: 2.1,
        py: 0.4,
        pulseFreq: 1.75,
        radiusFactor: 0.50,
        rgb: [72, 174, 255], // electric azure blue
        alpha: 0.40
      },
      {
        fx: 0.52,
        fy: 0.39,
        px: 4.2,
        py: 2.6,
        pulseFreq: 1.55,
        radiusFactor: 0.46,
        rgb: [196, 226, 255], // cool ice-white tint
        alpha: 0.26
      },
      {
        fx: 0.62,
        fy: 0.46,
        px: 1.4,
        py: 3.9,
        pulseFreq: 2.05,
        radiusFactor: 0.36,
        rgb: [255, 255, 255], // pure soft white light
        alpha: 0.22
      }
    ];

    section.addEventListener('pointermove', (e) => {
      const rect = section.getBoundingClientRect();
      look.tx = ((e.clientX - rect.left) / Math.max(1, rect.width) - 0.5) * 140;
      look.ty = ((e.clientY - rect.top) / Math.max(1, rect.height) - 0.5) * 90;
    });

    section.addEventListener('pointerleave', () => {
      look.tx = 0;
      look.ty = 0;
    });

    function resize() {
      const rect = section.getBoundingClientRect();
      width = Math.max(320, Math.round(rect.width));
      height = Math.max(320, Math.round(rect.height));
      canvas.width = Math.round(width * 0.5);
      canvas.height = Math.round(height * 0.5);
      ctx.setTransform(0.5, 0, 0, 0.5, 0, 0);
    }

    resize();
    window.addEventListener('resize', resize);

    function step(timeSec, dt) {
      if (width <= 0 || height <= 0) return;
      look.x += (look.tx - look.x) * clamp(dt * 4, 0, 1);
      look.y += (look.ty - look.y) * clamp(dt * 4, 0, 1);

      ctx.globalCompositeOperation = 'source-over';
      ctx.clearRect(0, 0, width, height);

      ctx.globalCompositeOperation = 'lighter';
      const baseDim = Math.max(width, height);

      for (let i = 0; i < orbs.length; i++) {
        const o = orbs[i];
        const wanderX = Math.sin(timeSec * o.fx + o.px) * 0.36 + Math.cos(timeSec * 0.29 + i) * 0.08;
        const wanderY = Math.cos(timeSec * o.fy + o.py) * 0.22 + Math.sin(timeSec * 0.33 + i) * 0.05;
        const cx = width * (0.5 + wanderX) + look.x * (0.45 + i * 0.16);
        const cy = height * (0.40 + wanderY) + look.y * (0.35 + i * 0.12);

        const breath = 1 + 0.15 * Math.sin(timeSec * o.pulseFreq + o.px);
        const r = baseDim * o.radiusFactor * breath;

        const grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
        const [red, green, blue] = o.rgb;
        const stops = 10;
        for (let s = 0; s <= stops; s++) {
          const t = s / stops;
          // Smooth Gaussian decay avoids visible gradient inflection rings
          const weight = s === stops ? 0 : Math.exp(-t * t * 4.4);
          grad.addColorStop(t, `rgba(${red}, ${green}, ${blue}, ${(o.alpha * weight).toFixed(4)})`);
        }

        ctx.fillStyle = grad;
        ctx.fillRect(0, 0, width, height);
      }
    }

    return { step };
  })();

  // =========================================================
  // BLOCK 03: DENSE SMALL PURE-BLACK FAST CURSOR-FOLLOWING DOTS
  // =========================================================
  const monochromeDotsField = (() => {
    const canvas = elements.bridgeCanvas;
    const card = elements.bridgeCard;
    if (!canvas || !card) return null;

    const ctx = canvas.getContext('2d');
    if (!ctx) return null;

    let width = 0;
    let height = 0;
    let dpr = 1;
    const pointer = { x: 0, y: 0, tx: 0, ty: 0, active: false, energy: 0 };
    const dots = [];
    const DOT_COUNT = 340;

    function buildDots() {
      dots.length = 0;
      const UNIFORM_RADIUS = 2.6;
      for (let i = 0; i < DOT_COUNT; i++) {
        const homeX = Math.random() * width;
        const homeY = Math.random() * height;
        const followStrength = lerp(0.45, 0.98, Math.random());
        const orbitOffsetAngle = Math.random() * Math.PI * 2;
        const orbitRadius = 14 + Math.pow(Math.random(), 0.75) * 145;

        dots.push({
          homeX,
          homeY,
          x: homeX,
          y: homeY,
          vx: 0,
          vy: 0,
          radius: UNIFORM_RADIUS,
          followStrength,
          orbitOffsetAngle,
          orbitRadius,
          driftPhase: Math.random() * Math.PI * 2,
          driftSpeed: 0.95 + Math.random() * 1.1
        });
      }
    }

    function resize() {
      const rect = card.getBoundingClientRect();
      width = Math.max(320, Math.round(rect.width));
      height = Math.max(320, Math.round(rect.height));
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = width * dpr;
      canvas.height = height * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      buildDots();
      if (!pointer.active) {
        pointer.x = pointer.tx = width * 0.5;
        pointer.y = pointer.ty = height * 0.5;
      }
    }

    resize();
    window.addEventListener('resize', resize);

    card.addEventListener('pointerenter', (e) => {
      const rect = card.getBoundingClientRect();
      pointer.tx = e.clientX - rect.left;
      pointer.ty = e.clientY - rect.top;
      if (!pointer.active) {
        pointer.x = pointer.tx;
        pointer.y = pointer.ty;
      }
      pointer.active = true;
    });

    card.addEventListener('pointermove', (e) => {
      const rect = card.getBoundingClientRect();
      pointer.tx = e.clientX - rect.left;
      pointer.ty = e.clientY - rect.top;
      pointer.active = true;
    });

    card.addEventListener('pointerleave', () => {
      pointer.active = false;
    });

    card.addEventListener('pointerdown', (e) => {
      const rect = card.getBoundingClientRect();
      const cx = e.clientX - rect.left;
      const cy = e.clientY - rect.top;
      for (const d of dots) {
        const dx = d.x - cx;
        const dy = d.y - cy;
        const dist = Math.max(12, Math.hypot(dx, dy));
        if (dist < 260) {
          const impulse = (1 - dist / 260) * 420;
          d.vx += (dx / dist) * impulse;
          d.vy += (dy / dist) * impulse;
        }
      }
    });

    function step(timeSec, dt) {
      if (width <= 0 || height <= 0) return;
      ctx.clearRect(0, 0, width, height);

      pointer.x += (pointer.tx - pointer.x) * clamp(dt * 22, 0, 1);
      pointer.y += (pointer.ty - pointer.y) * clamp(dt * 22, 0, 1);
      pointer.energy += ((pointer.active ? 1 : 0) - pointer.energy) * clamp(dt * 10, 0, 1);

      for (let i = 0; i < dots.length; i++) {
        const d = dots[i];
        // Brisk ambient drift
        const ambientX = d.homeX + Math.cos(timeSec * d.driftSpeed + d.driftPhase) * 18;
        const ambientY = d.homeY + Math.sin(timeSec * d.driftSpeed * 0.85 + d.driftPhase) * 18;

        // Fast orbital swarm formation following pointer
        const angle = d.orbitOffsetAngle + timeSec * 0.95 * (i % 2 === 0 ? 1 : -1);
        const clusterX = pointer.x + Math.cos(angle) * d.orbitRadius;
        const clusterY = pointer.y + Math.sin(angle) * d.orbitRadius;

        const followWeight = pointer.energy * d.followStrength;
        const targetX = lerp(ambientX, clusterX, followWeight);
        const targetY = lerp(ambientY, clusterY, followWeight);

        // Snappy spring response toward target
        const stiffness = lerp(5.5, 22.0, followWeight);
        const fx = (targetX - d.x) * stiffness;
        const fy = (targetY - d.y) * stiffness;

        const damping = Math.pow(0.015, dt);
        d.vx = (d.vx + fx * dt) * damping;
        d.vy = (d.vy + fy * dt) * damping;
        d.x += d.vx * dt;
        d.y += d.vy * dt;

        // Strictly solid #000000 black dots of identical size
        ctx.beginPath();
        ctx.arc(d.x, d.y, d.radius, 0, Math.PI * 2);
        ctx.fillStyle = '#000000';
        ctx.fill();
      }
    }

    return { step };
  })();

  const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  let marqueeLeftPeriod = 0;
  let marqueeRightPeriod = 0;

  function measureMarqueePeriods() {
    marqueeLeftPeriod = elements.marqueeLeft?.firstElementChild?.getBoundingClientRect().width || 0;
    marqueeRightPeriod = elements.marqueeRight?.firstElementChild?.getBoundingClientRect().width || 0;
  }

  measureMarqueePeriods();
  window.addEventListener('load', measureMarqueePeriods);
  window.addEventListener('resize', measureMarqueePeriods);
  if (document.fonts && document.fonts.ready) {
    document.fonts.ready.then(measureMarqueePeriods);
  }

  function updateMarquee(scrollY, nowMs) {
    const progress = scrollY * 0.22 + (prefersReducedMotion ? 0 : nowMs * 0.032);
    if (elements.marqueeLeft && marqueeLeftPeriod > 0) {
      const offset = ((progress % marqueeLeftPeriod) + marqueeLeftPeriod) % marqueeLeftPeriod;
      elements.marqueeLeft.style.transform = `translate3d(${-offset}px, 0, 0)`;
    }
    if (elements.marqueeRight && marqueeRightPeriod > 0) {
      const offset = ((progress % marqueeRightPeriod) + marqueeRightPeriod) % marqueeRightPeriod;
      elements.marqueeRight.style.transform = `translate3d(${offset - marqueeRightPeriod}px, 0, 0)`;
    }
  }

  function updateFooterMonument() {
    if (!elements.footerMonument || !elements.footerWordmark) return;
    const vh = window.innerHeight || 900;
    const rect = elements.footerMonument.getBoundingClientRect();
    const p = clamp((vh - rect.top) / Math.max(1, rect.height * 0.78), 0, 1);
    elements.footerWordmark.style.transform = `translate3d(0, ${lerp(18, 0, p)}px, 0) scaleX(0.82)`;
    elements.footerWordmark.style.opacity = `${lerp(0.45, 1.0, p)}`;
  }

  function tick(now) {
    const dt = clamp((now - lastFrameTime) / 1000, 0.001, 0.05);
    lastFrameTime = now;

    currentScroll = window.scrollY;
    const delta = currentScroll - smoothScroll;
    // Slower, gentler scroll damping for calmer animation
    const alpha = 1 - Math.exp(-4.2 * dt);
    smoothScroll = Math.abs(delta) < 0.15 ? currentScroll : smoothScroll + delta * alpha;

    updateHeroStage(smoothScroll);
    if (heroColorField) heroColorField.step(now * 0.001, dt);
    if (monochromeDotsField) monochromeDotsField.step(now * 0.001, dt);
    updateMarquee(smoothScroll, now);
    updateFooterMonument();

    requestAnimationFrame(tick);
  }

  requestAnimationFrame(tick);
})();
