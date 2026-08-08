// The only unit here that performs network I/O. Everything it returns is a
// plain record array, so the UI and payload layers never learn the 7TV API.
//
// Verified live 2026-08-08: GET https://7tv.io/v3/emote-sets/<id> returns
// { emotes: [{ id, name, data: { animated } }] }, and the API reflects the
// Origin header -- including `null` -- so this works from file:// and from
// GitHub Pages with no proxy.
window.DSTK = window.DSTK || {};
DSTK.sevenTV = (function () {

  var API = 'https://7tv.io/v3/emote-sets/';

  // ULIDs: 26 characters, Crockford base32 (no I, L, O, U). 'global' is the
  // documented well-known set and is accepted verbatim.
  var ID = /([A-HJKMNP-TV-Z0-9]{26})/i;

  function setIdFrom(input) {
    var s = String(input || '').trim();
    if (!s) return null;
    if (s.toLowerCase() === 'global') return 'global';
    var m = s.match(ID);
    return m ? m[1] : null;
  }

  function normalizeEmotes(json) {
    var emotes = (json && json.emotes) || [];
    return emotes.map(function (e) {
      return {
        id: e.id,
        name: e.name,
        source: '7',
        // 7TV states this outright, unlike link import (which infers it from a
        // file extension) and photo import (which sniffs the bytes). Taking it
        // is the whole reason the payload can carry a reliable animated flag.
        animated: !!(e.data && e.data.animated)
      };
    });
  }

  function fetchSet(setId) {
    return fetch(API + encodeURIComponent(setId))
      .then(function (r) {
        if (r.status === 404) throw new Error('No 7TV emote set with that id.');
        if (!r.ok) throw new Error("Couldn't reach 7TV — try again.");
        return r.json();
      })
      .then(normalizeEmotes);
  }

  return { setIdFrom: setIdFrom, normalizeEmotes: normalizeEmotes, fetchSet: fetchSet };
})();
