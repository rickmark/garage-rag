// Fills the download buttons on the landing page from the latest GitHub release.
//
// The page ships with every link pointing at the releases/latest page, so it
// works with JavaScript off, when the GitHub API is rate limited, or when a
// release carries no installer. This only upgrades those links to the direct
// Apple Silicon .pkg and shows the version and date.
(function () {
  'use strict';

  var REPO = 'rickmark/garage-rag';
  var API = 'https://api.github.com/repos/' + REPO + '/releases/latest';
  var INSTALLER = 'GarageInstaller_arm64.pkg';

  function byId(id) { return document.getElementById(id); }

  function formatSize(bytes) {
    if (!bytes) { return ''; }
    return (bytes / (1024 * 1024)).toFixed(0) + ' MB';
  }

  function formatDate(iso) {
    if (!iso) { return ''; }
    try {
      return new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'long', day: 'numeric' }).format(new Date(iso));
    } catch (e) {
      return iso.slice(0, 10);
    }
  }

  function apply(release) {
    var version = (release.tag_name || '').replace(/^v/, '');
    var installer = null;
    (release.assets || []).forEach(function (asset) {
      if (asset.name === INSTALLER && asset.state === 'uploaded') { installer = asset; }
    });

    ['download-release', 'download-release-aside'].forEach(function (id) {
      var a = byId(id);
      if (a && release.html_url) { a.href = release.html_url; }
    });

    if (!installer) { return; }

    ['download-primary', 'download-pkg'].forEach(function (id) {
      var a = byId(id);
      if (a) { a.href = installer.browser_download_url; }
    });

    var title = byId('download-title');
    if (title && version) { title.textContent = 'Garage ' + version + ' for Mac'; }

    var primary = byId('download-primary');
    if (primary && version) { primary.textContent = '⬇︎ Download Garage ' + version; }

    var parts = [];
    if (version) { parts.push('Version ' + version); }
    var date = formatDate(release.published_at);
    if (date) { parts.push(date); }
    var size = formatSize(installer.size);
    if (size) { parts.push(size); }
    parts.push('Apple Silicon');
    parts.push('macOS 14 or later');

    var meta = byId('download-meta');
    if (meta) { meta.textContent = parts.join(' · '); }

    var detail = byId('download-detail');
    if (detail) {
      detail.innerHTML = '';
      detail.appendChild(document.createTextNode(
        'Apple Silicon (M1 and later), macOS 14 Sonoma or later. ' + INSTALLER +
        (size ? ' (' + size + ')' : '') + ', signed and notarized' + (date ? ', released ' + date + '.' : '.')
      ));
    }
  }

  function load() {
    if (!window.fetch || !byId('download-primary')) { return; }
    fetch(API, { headers: { Accept: 'application/vnd.github+json' } })
      .then(function (response) {
        if (!response.ok) { throw new Error('GitHub API ' + response.status); }
        return response.json();
      })
      .then(apply)
      .catch(function () { /* keep the static releases/latest links */ });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', load);
  } else {
    load();
  }
})();
