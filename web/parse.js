// Pure text-to-record parsing. No network, no DOM, no state.
//
// The record shape every unit here passes around:
//   { id, name, source: 'd' | '7', animated: bool }
// The DSTK1 tag is derived from source + animated rather than stored, because
// the UI needs `source` on its own to build thumbnail URLs.
window.DSTK = window.DSTK || {};
DSTK.parse = (function () {

  // Character-for-character the pattern in EmojiMarkupParser.swift:8. The two
  // implementations are checked against the same corpus.json by both suites;
  // changing one without the other breaks CorpusParityTests.
  var MARKUP = /<(a)?:([A-Za-z0-9_]+):(\d+)>/g;

  var DISCORD_URL = /cdn\.discordapp\.com\/emojis\/(\d+)(?:\.(\w+))?/i;
  var SEVENTV_URL = /cdn\.7tv\.app\/emote\/([A-Za-z0-9]+)(?:\/\w+\.(\w+))?/i;
  var BARE_ID = /^\d+$/;

  function discordMarkup(text) {
    var seen = Object.create(null);
    var out = [];
    var m;
    MARKUP.lastIndex = 0;   // /g regexes carry state between calls
    while ((m = MARKUP.exec(text)) !== null) {
      var id = m[3];
      if (seen[id]) continue;
      seen[id] = true;
      out.push({ id: id, name: m[2], source: 'd', animated: m[1] === 'a' });
    }
    return out;
  }

  // Returns rejections rather than dropping them: a user who pastes 40 lines
  // and gets 38 emoji needs to know which two failed and why. Silently
  // importing 38 is the worse outcome.
  function rawLines(text) {
    var seen = Object.create(null);
    var records = [];
    var rejected = [];

    String(text).split(/\r?\n/).forEach(function (raw) {
      var line = raw.trim();
      if (!line) return;                       // blank is not a rejection

      var rec = null, reason = null, m;

      if ((m = line.match(DISCORD_URL))) {
        rec = { id: m[1], name: m[1], source: 'd',
                animated: (m[2] || '').toLowerCase() === 'gif' };

      } else if ((m = line.match(SEVENTV_URL))) {
        var ext = (m[2] || '').toLowerCase();
        if (ext === 'gif') {
          rec = { id: m[1], name: m[1], source: '7', animated: true };
        } else if (ext === 'webp' || ext === 'avif' || ext === 'png') {
          rec = { id: m[1], name: m[1], source: '7', animated: false };
        } else {
          // Deliberately not defaulted. Discord self-heals a wrong format guess
          // with a 415 the downloader retries; 7TV answers 200 with a valid
          // still image instead, so a guess that misses here is permanent and
          // invisible. Better to ask than to import something that silently
          // never moves.
          reason = 'needs the full 7TV image URL, ending .gif or .webp';
        }

      } else if (BARE_ID.test(line)) {
        // Static is the safe default only because it is Discord: a static
        // request for an animated emoji returns 415, which the phone retries
        // as .gif. The same default would be unsafe for 7TV, which is why a
        // bare 7TV id has no branch here.
        rec = { id: line, name: line, source: 'd', animated: false };

      } else {
        reason = 'not an emoji id or a CDN link';
      }

      if (reason) { rejected.push({ line: line, reason: reason }); return; }
      if (seen[rec.id]) return;
      seen[rec.id] = true;
      records.push(rec);
    });

    return { records: records, rejected: rejected };
  }

  // A DSTK1 payload is this page's *output*. Pasting one back in is an easy
  // mistake -- it looks like the kind of text the page eats -- and every input
  // here would otherwise reject it with a message about the wrong thing
  // entirely ("No 7TV emote set with that id").
  //
  // Matches a header at the start even when newlines have been flattened to
  // spaces, which is what happens when a payload is pasted into a
  // single-line field.
  function looksLikePayload(text) {
    return /^\s*DSTK1(\s|$)/.test(String(text || ''));
  }

  return {
    discordMarkup: discordMarkup,
    rawLines: rawLines,
    looksLikePayload: looksLikePayload
  };
})();
