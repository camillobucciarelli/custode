// Language handling, nothing else. Loaded in <head> without defer so the one-time redirect runs before the page paints.
(function () {
  var KEY = 'custode-lang';
  function stored() { try { return localStorage.getItem(KEY); } catch (e) { return null; } }
  function store(lang) { try { localStorage.setItem(KEY, lang); } catch (e) { /* private mode: the choice lasts for this navigation only */ } }

  // Root English home only: a first-time visitor whose browser is Italian goes to the Italian home, once.
  if (document.documentElement.hasAttribute('data-root-home') && !stored() &&
      (navigator.language || '').toLowerCase().indexOf('it') === 0) {
    store('it');
    location.replace('it/index.html');
    return;
  }

  // Without script the header shows a plain link to the other language; with script, a native select replaces it.
  document.addEventListener('DOMContentLoaded', function () {
    var select = document.querySelector('.lang-select'), link = document.querySelector('.lang-link');
    if (!select) return;
    select.hidden = false;
    if (link) link.hidden = true;
    // Back/forward cache restores the select as the visitor left it: put it back on this page's language.
    window.addEventListener('pageshow', function () { select.value = ''; });
    select.addEventListener('change', function () {
      var option = select.options[select.selectedIndex];
      store(option.lang);
      if (option.value) location.href = option.value;
    });
  });
})();
