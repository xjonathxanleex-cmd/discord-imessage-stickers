// Minimal runner. No framework, deliberately: the page has no build step and
// no package manager, and a test harness that needed either would defeat that.
(function () {
  var results = [];
  var failures = 0;

  window.test = function (name, fn) {
    try { fn(); results.push({ name: name, ok: true }); }
    catch (e) { failures++; results.push({ name: name, ok: false, msg: e.message }); }
  };

  window.assertEqual = function (actual, expected, what) {
    if (actual !== expected) {
      throw new Error((what || '') + ' expected ' + JSON.stringify(expected) +
                      ', got ' + JSON.stringify(actual));
    }
  };

  window.assertDeepEqual = function (actual, expected, what) {
    var a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error((what || '') + ' expected ' + e + ', got ' + a);
  };

  window.reportResults = function () {
    var summary = failures === 0
      ? '✅ all ' + results.length + ' passed'
      : '❌ ' + failures + ' of ' + results.length + ' failed';
    document.getElementById('summary').textContent = summary;
    document.getElementById('summary').className = failures === 0 ? 'pass' : 'fail';

    // Built with textContent rather than innerHTML: failure messages quote the
    // actual input that failed, and corpus.json is full of angle brackets.
    // An assertion message would otherwise be parsed as markup -- garbling the
    // very output you are reading to work out what broke.
    var out = document.getElementById('results');
    out.textContent = '';
    results.forEach(function (r) {
      var row = document.createElement('div');
      row.className = r.ok ? 'pass' : 'fail';
      row.textContent = (r.ok ? '✓ ' : '✗ ') + r.name + (r.msg ? ' — ' + r.msg : '');
      out.appendChild(row);
    });
    if (window.__onTestsDone) window.__onTestsDone(failures, results);
  };
})();

// --- harness self-check -----------------------------------------------------

test('the harness itself reports failures', function () {
  var caught = false;
  try { assertEqual(1, 2, 'deliberate'); } catch (e) { caught = true; }
  assertEqual(caught, true, 'assertEqual must throw on mismatch');
});

test('vendored QR encoder loaded and encodes', function () {
  var q = qrcode(0, 'M');
  q.addData('DSTK1', 'Byte');
  q.make();
  assertEqual(q.getModuleCount() > 0, true, 'module count');
});

// --- Discord markup ---------------------------------------------------------

test('discordMarkup: single static emoji', function () {
  assertDeepEqual(DSTK.parse.discordMarkup('hi <:67:1481800758532903104>'),
    [{ id: '1481800758532903104', name: '67', source: 'd', animated: false }]);
});

test('discordMarkup: animated marker sets animated', function () {
  assertDeepEqual(DSTK.parse.discordMarkup('<a:catJAM:1095953169969860649>'),
    [{ id: '1095953169969860649', name: 'catJAM', source: 'd', animated: true }]);
});

test('discordMarkup: duplicate ids collapse, first wins', function () {
  var r = DSTK.parse.discordMarkup('<:a:111> <:b:111>');
  assertEqual(r.length, 1, 'length');
  assertEqual(r[0].name, 'a', 'first occurrence wins');
});

test('discordMarkup: order preserved, not sorted', function () {
  var r = DSTK.parse.discordMarkup('<:third:3> <:first:1> <:second:2>');
  assertDeepEqual(r.map(function (e) { return e.id; }), ['3', '1', '2']);
});

test('discordMarkup: invalid name characters do not match', function () {
  assertDeepEqual(DSTK.parse.discordMarkup('<:not-valid:123>'), []);
});

test('discordMarkup: non-numeric id does not match', function () {
  assertDeepEqual(DSTK.parse.discordMarkup('<:name:abc>'), []);
});

test('discordMarkup: empty input yields empty array', function () {
  assertDeepEqual(DSTK.parse.discordMarkup(''), []);
});

test('discordMarkup: every record is tagged source d', function () {
  var r = DSTK.parse.discordMarkup('<:a:1><a:b:2>');
  assertEqual(r.every(function (e) { return e.source === 'd'; }), true, 'all source d');
});

test('discordMarkup: a second call is not affected by regex lastIndex state', function () {
  var text = '<:a:1> <:b:2> <:c:3>';
  var first = DSTK.parse.discordMarkup(text);
  var second = DSTK.parse.discordMarkup(text);
  assertDeepEqual(second, first, 'repeat call must match the first');
});

// --- raw ids and links ------------------------------------------------------

test('rawLines: bare id becomes a static Discord record', function () {
  var r = DSTK.parse.rawLines('1481800758532903104');
  assertDeepEqual(r.records,
    [{ id: '1481800758532903104', name: '1481800758532903104', source: 'd', animated: false }]);
  assertEqual(r.rejected.length, 0, 'no rejections');
});

test('rawLines: Discord CDN url, png is static', function () {
  var r = DSTK.parse.rawLines('https://cdn.discordapp.com/emojis/123.png');
  assertEqual(r.records[0].id, '123', 'id');
  assertEqual(r.records[0].animated, false, 'static');
  assertEqual(r.records[0].source, 'd', 'source');
});

test('rawLines: Discord CDN url, gif is animated', function () {
  var r = DSTK.parse.rawLines('https://cdn.discordapp.com/emojis/123.gif');
  assertEqual(r.records[0].animated, true, 'animated');
});

test('rawLines: query parameters are ignored', function () {
  var r = DSTK.parse.rawLines('https://cdn.discordapp.com/emojis/456.gif?size=96&quality=lossless');
  assertEqual(r.records[0].id, '456', 'id');
  assertEqual(r.records[0].animated, true, 'animated');
});

test('rawLines: 7TV url with gif is animated 7TV', function () {
  var r = DSTK.parse.rawLines('https://cdn.7tv.app/emote/01FCY771D800007PQ2DF3GDTN6/4x.gif');
  assertDeepEqual(r.records, [{
    id: '01FCY771D800007PQ2DF3GDTN6', name: '01FCY771D800007PQ2DF3GDTN6',
    source: '7', animated: true }]);
});

test('rawLines: 7TV url with webp is static 7TV', function () {
  var r = DSTK.parse.rawLines('https://cdn.7tv.app/emote/01GAZ199Z8000FEWHS6AT5QZV0/4x.webp');
  assertEqual(r.records[0].animated, false, 'static');
  assertEqual(r.records[0].source, '7', 'source');
});

test('rawLines: 7TV url with no usable extension is REJECTED, not guessed', function () {
  var r = DSTK.parse.rawLines('https://cdn.7tv.app/emote/01GAZ199Z8000FEWHS6AT5QZV0');
  assertEqual(r.records.length, 0, 'nothing imported');
  assertEqual(r.rejected.length, 1, 'one rejection');
});

test('rawLines: junk line is rejected but the batch survives', function () {
  var r = DSTK.parse.rawLines('not an id\n123\nalso junk');
  assertEqual(r.records.length, 1, 'the good line still imported');
  assertEqual(r.records[0].id, '123', 'id');
  assertEqual(r.rejected.length, 2, 'two rejections');
});

test('rawLines: blank lines and whitespace are skipped silently', function () {
  var r = DSTK.parse.rawLines('\n  \n123\n\n   \n');
  assertEqual(r.records.length, 1, 'one record');
  assertEqual(r.rejected.length, 0, 'blank lines are not rejections');
});

test('rawLines: duplicate ids collapse across mixed shapes', function () {
  var r = DSTK.parse.rawLines('123\nhttps://cdn.discordapp.com/emojis/123.gif');
  assertEqual(r.records.length, 1, 'deduped');
  assertEqual(r.records[0].animated, false, 'first occurrence wins');
});

// --- 7TV --------------------------------------------------------------------

test('setIdFrom: a bare id passes through', function () {
  assertEqual(DSTK.sevenTV.setIdFrom('01F6MZGCNG000255K4X1K7EMS7'), '01F6MZGCNG000255K4X1K7EMS7');
});

test('setIdFrom: extracts from a 7tv.app emote-set url', function () {
  assertEqual(DSTK.sevenTV.setIdFrom('https://7tv.app/emote-sets/01F6MZGCNG000255K4X1K7EMS7'),
    '01F6MZGCNG000255K4X1K7EMS7');
});

test('setIdFrom: extracts from a url with a trailing slash', function () {
  assertEqual(DSTK.sevenTV.setIdFrom('https://7tv.app/emote-sets/01F6MZGCNG000255K4X1K7EMS7/'),
    '01F6MZGCNG000255K4X1K7EMS7');
});

test('setIdFrom: the literal global set is allowed', function () {
  assertEqual(DSTK.sevenTV.setIdFrom('global'), 'global');
});

test('setIdFrom: junk yields null', function () {
  assertEqual(DSTK.sevenTV.setIdFrom('not a set'), null);
  assertEqual(DSTK.sevenTV.setIdFrom(''), null);
});

test('normalizeEmotes: maps the API shape to records', function () {
  var api = { emotes: [
    { id: 'AAA', name: 'RainTime', data: { animated: true } },
    { id: 'BBB', name: 'peepoHappy', data: { animated: false } }] };
  assertDeepEqual(DSTK.sevenTV.normalizeEmotes(api), [
    { id: 'AAA', name: 'RainTime', source: '7', animated: true },
    { id: 'BBB', name: 'peepoHappy', source: '7', animated: false }]);
});

test('normalizeEmotes: a missing data block is treated as static, not dropped', function () {
  var r = DSTK.sevenTV.normalizeEmotes({ emotes: [{ id: 'C', name: 'x' }] });
  assertEqual(r.length, 1, 'kept');
  assertEqual(r[0].animated, false, 'defaults static');
});

test('normalizeEmotes: an absent emotes array yields empty, not a throw', function () {
  assertDeepEqual(DSTK.sevenTV.normalizeEmotes({}), []);
});

// --- payload ----------------------------------------------------------------

test('build: header only for an empty selection', function () {
  assertEqual(DSTK.payload.build([]), 'DSTK1');
});

test('build: one line per record with the right tag', function () {
  assertEqual(DSTK.payload.build([
    { id: '1', name: 'a', source: 'd', animated: false },
    { id: '2', name: 'b', source: 'd', animated: true },
    { id: '3', name: 'c', source: '7', animated: false },
    { id: '4', name: 'd', source: '7', animated: true }]),
    'DSTK1\nd 1 a\nda 2 b\n7 3 c\n7a 4 d');
});

test('build: names containing spaces survive', function () {
  assertEqual(DSTK.payload.build([{ id: '1', name: 'cat jam party', source: 'd', animated: false }]),
    'DSTK1\nd 1 cat jam party');
});

test('build: names are truncated to 64 characters', function () {
  var long = new Array(101).join('x');
  var out = DSTK.payload.build([{ id: '1', name: long, source: 'd', animated: false }]);
  assertEqual(out.split(' ')[2].length, 64, 'name length');
});

test('build: newlines inside a name are stripped, not emitted', function () {
  var out = DSTK.payload.build([{ id: '1', name: 'two\nlines', source: 'd', animated: false }]);
  assertEqual(out.split('\n').length, 2, 'still one record line');
});

test('byteLength: counts UTF-8 bytes, not characters', function () {
  assertEqual(DSTK.payload.byteLength('abc'), 3, 'ascii');
  assertEqual(DSTK.payload.byteLength('é'), 2, 'two-byte char');
  assertEqual(DSTK.payload.byteLength('🎉'), 4, 'four-byte char');
});

test('chunk: a small selection is a single chunk', function () {
  var recs = [{ id: '1', name: 'a', source: 'd', animated: false }];
  assertEqual(DSTK.payload.chunk(recs).length, 1);
});

test('chunk: every chunk carries the header', function () {
  var recs = [];
  for (var i = 0; i < 200; i++) {
    recs.push({ id: '10000000000000000' + i, name: 'name' + i, source: 'd', animated: false });
  }
  var chunks = DSTK.payload.chunk(recs);
  assertEqual(chunks.length > 1, true, 'did split');
  assertEqual(chunks.every(function (c) { return c.indexOf('DSTK1\n') === 0; }), true, 'all headed');
});

test('chunk: chunks reassemble to exactly the input, nothing lost or duplicated', function () {
  var recs = [];
  for (var i = 0; i < 200; i++) {
    recs.push({ id: '10000000000000000' + i, name: 'name' + i, source: 'd', animated: false });
  }
  var ids = [];
  DSTK.payload.chunk(recs).forEach(function (c) {
    c.split('\n').slice(1).forEach(function (line) { ids.push(line.split(' ')[1]); });
  });
  assertDeepEqual(ids, recs.map(function (r) { return r.id; }));
});

test('chunk: no chunk exceeds the byte budget', function () {
  // 7TV ids (26 chars) and the two-character `7a` tag are the worst case; using
  // short Discord ids here would let a count-based chunker slip under the
  // budget by luck and pass.
  var recs = [];
  for (var i = 0; i < 300; i++) {
    recs.push({ id: '01FCY771D800007PQ2DF3GDT' + i, name: 'emote' + i, source: '7', animated: true });
  }
  DSTK.payload.chunk(recs).forEach(function (c) {
    assertEqual(DSTK.payload.byteLength(c) <= DSTK.payload.MAX_CHUNK_BYTES, true,
      'chunk of ' + DSTK.payload.byteLength(c) + ' bytes');
  });
});

test('chunk: SPLITS BY BYTES NOT COUNT — same count, longer ids, more chunks', function () {
  // n must be large enough that the two id lengths land on *different* chunk
  // counts. At n=60 both need 2 chunks (1265 vs 1925 bytes against a 1200-byte
  // budget) and the assertion cannot discriminate -- it passes against a
  // count-based implementation, which is the exact bug it exists to catch.
  var n = 100;
  var shortIds = [], longIds = [];
  for (var i = 0; i < n; i++) {
    shortIds.push({ id: '14818007585329' + i, name: 'nm', source: 'd', animated: false });
    longIds.push({ id: '01FCY771D800007PQ2DF3GDT' + i, name: 'nm', source: '7', animated: true });
  }
  var a = DSTK.payload.chunk(shortIds).length;
  var b = DSTK.payload.chunk(longIds).length;
  assertEqual(b > a, true, 'longer 7TV ids must need more chunks (' + a + ' vs ' + b + ')');
});

test('chunk: every emitted chunk actually encodes as a QR', function () {
  var recs = [];
  for (var i = 0; i < 250; i++) {
    recs.push({ id: '01FCY771D800007PQ2DF3GDT' + i, name: 'emote' + i, source: '7', animated: true });
  }
  DSTK.payload.chunk(recs).forEach(function (c, i) {
    var q = qrcode(0, DSTK.payload.QR_EC);
    q.addData(c, 'Byte');
    q.make();                       // throws if the chunk does not fit
    assertEqual(q.getModuleCount() > 0, true, 'chunk ' + i);
  });
});

test('chunk: a single record too large to ever fit still yields a chunk', function () {
  var huge = { id: '1', name: new Array(65).join('x'), source: 'd', animated: false };
  assertEqual(DSTK.payload.chunk([huge]).length, 1, 'not an infinite loop');
});

test('chunk: the 500-emoji cap is enforced', function () {
  var recs = [];
  for (var i = 0; i < 600; i++) {
    recs.push({ id: 'id' + i, name: 'n', source: 'd', animated: false });
  }
  var lines = 0;
  DSTK.payload.chunk(recs).forEach(function (c) { lines += c.split('\n').length - 1; });
  assertEqual(lines, 500, 'capped at maxPayloadEmoji');
});

// --- shared corpus ----------------------------------------------------------
// Runs the shared corpus through the page's parser. Needs fetch, which file://
// blocks -- see README for the one-line server. Skips loudly rather than
// silently passing when the corpus cannot be loaded.
(function () {
  fetch('corpus.json')
    .then(function (r) { return r.json(); })
    .then(function (cases) {
      cases.forEach(function (c) {
        test('corpus: ' + c.why, function () {
          var got = DSTK.parse.discordMarkup(c.input).map(function (e) {
            return { id: e.id, name: e.name, animated: e.animated };
          });
          assertDeepEqual(got, c.expect);
        });
      });
    })
    .catch(function (e) {
      test('corpus: LOADED', function () {
        throw new Error('could not load corpus.json (' + e.message +
                        ') — run from a server, see README');
      });
    })
    .then(reportResults);
})();
