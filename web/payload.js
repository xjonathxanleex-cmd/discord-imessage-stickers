// Pure. Records in, DSTK1 text out, then split into QR-sized pieces.
window.DSTK = window.DSTK || {};
DSTK.payload = (function () {

  var HEADER = 'DSTK1';
  var MAX_NAME = 64;          // StickerLimits.maxStickerNameLength
  var MAX_EMOJI = 500;        // StickerLimits.maxPayloadEmoji

  // Measured against the vendored encoder: error correction M tops out at 2331
  // bytes, which needs a 177-module code -- the densest QR that exists, and
  // genuinely hard to scan off a laptop screen. 1200 bytes lands at 133 modules
  // and reads first time. The binding constraint here is the camera, not
  // capacity.
  var MAX_CHUNK_BYTES = 1200;   // mutable only via chunkForURL's swap below
  var QR_EC = 'M';

  var encoder = new TextEncoder();

  // UTF-8 bytes, not characters. Names may contain non-ASCII, and QR capacity
  // is denominated in bytes -- String.length would under-count and overflow.
  function byteLength(s) { return encoder.encode(s).length; }

  function tagFor(r) { return r.source + (r.animated ? 'a' : ''); }

  function lineFor(r) {
    // The name runs to end of line, so a newline inside one would forge an
    // extra record. Spaces are fine and deliberately preserved -- the parser
    // splits on the first two only.
    var name = String(r.name).replace(/[\r\n]+/g, ' ').trim().slice(0, MAX_NAME);
    return tagFor(r) + ' ' + r.id + ' ' + name;
  }

  function build(records) {
    var lines = records.slice(0, MAX_EMOJI).map(lineFor);
    return lines.length ? HEADER + '\n' + lines.join('\n') : HEADER;
  }

  function chunk(records) {
    var capped = records.slice(0, MAX_EMOJI);
    if (!capped.length) return [HEADER];

    var chunks = [];
    var current = [];
    var size = byteLength(HEADER);

    capped.forEach(function (r) {
      var line = lineFor(r);
      var cost = byteLength(line) + 1;              // + the newline
      // The `current.length` guard is what stops a single oversized record from
      // looping forever: an entry that cannot fit an empty chunk is emitted
      // alone and over budget rather than deferred to a chunk that will never
      // be emptier.
      if (current.length && size + cost > MAX_CHUNK_BYTES) {
        chunks.push(HEADER + '\n' + current.join('\n'));
        current = [];
        size = byteLength(HEADER);
      }
      current.push(line);
      size += cost;
    });

    if (current.length) chunks.push(HEADER + '\n' + current.join('\n'));
    return chunks;
  }

  // --- QR transfer -------------------------------------------------------
  //
  // A QR holding the raw payload does not work on iOS. The Camera app cannot
  // hand plain text to an app, so it treats anything non-URL as a web search
  // -- a scan produced a Google results page full of jumbled letters.
  //
  // So the QR carries a URL back to this page with the payload in the
  // fragment. Scanning opens the page on the phone, which sees the fragment
  // and offers a Copy button. The fragment is never sent to the server by any
  // browser, so a payload still never leaves the two devices.

  // base64url: no padding, and none of the characters that would need
  // percent-escaping inside a URL. Costs a flat 4/3 -- predictable, unlike
  // encodeURIComponent, where every space and newline in a payload becomes
  // three bytes and the total depends on how people named their emoji.
  function encodeForURL(text) {
    var bytes = encoder.encode(text);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function decodeFromURL(fragment) {
    var padded = fragment.replace(/-/g, '+').replace(/_/g, '/');
    while (padded.length % 4) padded += '=';
    var binary = atob(padded);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  }

  /// Budget for the payload itself, once the URL prefix and base64's 4/3
  /// expansion are paid for. Derived rather than guessed, so changing
  /// MAX_CHUNK_BYTES or moving the page to a longer URL cannot silently
  /// overflow a code.
  function payloadBudget(baseURL) {
    var overhead = byteLength(baseURL) + 1;          // + the '#'
    return Math.floor((MAX_CHUNK_BYTES - overhead) * 3 / 4);
  }

  /// Chunks sized so that each *URL* fits the QR budget, not each payload.
  function chunkForURL(records, baseURL) {
    var budget = payloadBudget(baseURL);
    var saved = MAX_CHUNK_BYTES;
    MAX_CHUNK_BYTES = budget;
    var chunks;
    try { chunks = chunk(records); } finally { MAX_CHUNK_BYTES = saved; }
    return chunks.map(function (c) { return baseURL + '#' + encodeForURL(c); });
  }

  return {
    HEADER: HEADER, get MAX_CHUNK_BYTES() { return MAX_CHUNK_BYTES; }, QR_EC: QR_EC,
    byteLength: byteLength, tagFor: tagFor, build: build, chunk: chunk,
    encodeForURL: encodeForURL, decodeFromURL: decodeFromURL,
    payloadBudget: payloadBudget, chunkForURL: chunkForURL
  };
})();
