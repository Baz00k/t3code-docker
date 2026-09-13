// A link from T3 Code back to the setup console, injected into T3 Code's
// client shell at image build time by scripts/patch-t3-client.mjs.
//
// The two services are separate processes on separate ports, and nothing in
// T3 Code knows the console exists. A user who lands on the T3 UI first and
// meets the pairing screen has nowhere to go next - the README is the only
// route back. This closes that seam without touching T3's React tree, which
// changes shape with every upstream release.
//
// It probes for the console on this origin (the documented route puts it at
// /__setup) and renders nothing when it is not there, so a deployment that
// does not route the console keeps exactly the upstream UI.
//
// Keep this file self-contained: it is inlined into an HTML script tag, so it
// must never contain a closing script tag sequence.
(() => {
  const PROBE_PATHS = ['/__setup/', '/setup/'];
  const MARKER = '<title>T3 Code setup</title>';

  const looksLikeSetup = async (path) => {
    try {
      const res = await fetch(path);
      if (!res.ok) return false;
      if (!(res.headers.get('content-type') || '').includes('text/html')) return false;
      return (await res.text()).includes(MARKER);
    } catch {
      return false;
    }
  };

  const render = (path) => {
    if (document.querySelector('.t3-setup-pill')) return;

    const style = document.createElement('style');
    style.textContent = [
      '.t3-setup-pill{position:fixed;left:14px;bottom:14px;z-index:2147483646;',
      'display:inline-flex;align-items:center;gap:7px;padding:7px 12px 7px 10px;',
      'border-radius:999px;border:1px solid rgba(0,0,0,.14);',
      'background:rgba(255,255,255,.92);color:#262626;',
      'font:500 12px/1.1 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;',
      'text-decoration:none;box-shadow:0 2px 10px rgba(0,0,0,.14);',
      'backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);}',
      '.t3-setup-pill:hover{border-color:rgba(0,0,0,.3);color:#000;}',
      'html.dark .t3-setup-pill{background:rgba(23,23,23,.9);color:#f5f5f5;',
      'border-color:rgba(255,255,255,.16);}',
      'html.dark .t3-setup-pill:hover{border-color:rgba(255,255,255,.36);color:#fff;}',
      '.t3-setup-pill svg{width:13px;height:13px;flex:none;}',
    ].join('');

    const link = document.createElement('a');
    link.className = 't3-setup-pill';
    link.href = path;
    link.target = '_blank';
    link.rel = 'noopener';
    link.title = 'Pair a device or manage this server';
    link.setAttribute('aria-label', 'Open the T3 Code setup console');
    link.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"'
      + ' stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
      + '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0'
      + 'l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51'
      + 'a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08'
      + 'a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18'
      + 'a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39'
      + 'a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09'
      + 'a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25'
      + 'a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/>'
      + '<circle cx="12" cy="12" r="3"/>'
      + '</svg><span>Setup</span>';

    document.head.appendChild(style);
    document.body.appendChild(link);
  };

  const start = async () => {
    for (const path of PROBE_PATHS) {
      if (await looksLikeSetup(path)) return render(path);
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
