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
  var MAX_CHUNK_BYTES = 1200;
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

  return {
    HEADER: HEADER, MAX_CHUNK_BYTES: MAX_CHUNK_BYTES, QR_EC: QR_EC,
    byteLength: byteLength, tagFor: tagFor, build: build, chunk: chunk
  };
})();
