# Desktop Companion Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A static web page that gathers Discord and 7TV emoji on a computer and emits a `DSTK1` transfer payload as copyable text and scannable QR codes.

**Architecture:** One directory of plain files with no build step. Classic `<script>` tags (not ES modules) writing onto a single `window.DSTK` namespace, so the page works when opened directly from disk as well as from GitHub Pages. Three pure parsing units and one pure payload unit, each independently testable, plus a thin DOM layer that owns all state and all I/O.

**Tech Stack:** Vanilla HTML/CSS/JS, no framework, no bundler, no package manager. One vendored MIT-licensed QR encoder. Tests run in the browser via a plain runner page.

## Global Constraints

- **No build step, no dependencies, no package manager.** A contributor clones and opens a file.
- **Classic scripts only — no `import`/`export`, no `type="module"`.** ES modules are blocked by CORS on `file://`, which would break opening the page from disk.
- **Nothing is stored.** No `localStorage`, no cookies, no `sessionStorage`, no server. Reloading clears everything.
- **The page handles names and URLs only.** It never fetches, proxies, re-hosts, or embeds emoji image *data* — thumbnails are `<img src>` pointing at the origin CDN, and the phone does every real fetch itself.
- **`DSTK1` payload format** (from the spec, §3) — line 1 is exactly `DSTK1`; each later line is `<tag> <id> <name>` where name runs to end of line. Tags: `d` Discord static, `da` Discord animated, `7` 7TV static, `7a` 7TV animated.
- **Discord markup pattern is `<(a)?:([A-Za-z0-9_]+):(\d+)>`** — character-for-character the same as `EmojiMarkupParser.swift:8`. Dedupe by id, first occurrence wins, original left-to-right order preserved.
- **Chunking is by UTF-8 bytes, never by emoji count.** `MAX_CHUNK_BYTES = 1200`, `QR_EC = 'M'`.
- **Byte counts use `new TextEncoder().encode(s).length`**, never `String.length`. Names may contain non-ASCII.
- **Max 500 emoji in one payload**, matching `StickerLimits.maxPayloadEmoji`.
- **Max name length 64 characters**, matching `StickerLimits.maxStickerNameLength`.
- CDN bases, verified live 2026-08-08:
  - Discord `https://cdn.discordapp.com/emojis/<id>.<png|gif>`
  - 7TV `https://cdn.7tv.app/emote/<id>/<1x|4x>.<webp|gif>`

---

## File Structure

| File | Responsibility |
|---|---|
| `web/index.html` | Markup and inline CSS. Script tags in dependency order. No logic. |
| `web/vendor/qrcode.js` | Vendored QR encoder, MIT, **verbatim — never edited** |
| `web/parse.js` | Pure. Text → emoji records. Three entry points, no I/O. |
| `web/sevenTV.js` | The only unit that performs network I/O. Fetch + normalize. |
| `web/payload.js` | Pure. Records → `DSTK1` text → byte-driven chunks. |
| `web/app.js` | DOM, events, all mutable state. The only file that touches the document. |
| `web/test.html` | Test runner page |
| `web/test.js` | Tests |
| `web/corpus.json` | Discord markup cases shared with the Swift suite |
| `DiscordStickers/StickerKitTests/CorpusParityTests.swift` | Proves the two parsers agree |

**The emoji record** is the type every unit passes around. Defined once, used everywhere:

```js
{ id: "1481800758532903104", name: "67", source: "d", animated: false }
```

`source` is `"d"` or `"7"`; `animated` is a boolean. The payload tag is derived
(`source + (animated ? "a" : "")`) rather than stored, because the UI needs `source` on its own
to build thumbnail URLs.

---

### Task 1: Scaffold, vendored encoder, and a working test runner

Nothing else can be verified until the runner runs. This task ends with one passing test that
proves the harness itself works.

**Files:**
- Create: `web/vendor/qrcode.js`, `web/test.html`, `web/test.js`, `web/README.md`

**Interfaces:**
- Produces: `window.DSTK` namespace object; `test(name, fn)` / `assertEqual` / `assertDeepEqual` / `assertThrows` in `test.js`; the global `qrcode(typeNumber, errorCorrectionLevel)` factory from the vendored file.

- [ ] **Step 1: Vendor the QR encoder**

Download it verbatim. Do not reformat, minify, or edit it — it is third-party MIT code and must
stay diffable against upstream.

```bash
mkdir -p web/vendor
curl -sL -o web/vendor/qrcode.js "https://cdn.jsdelivr.net/npm/qrcode-generator@1.4.4/qrcode.js"
```

Verify it arrived intact — expect `2297` lines and the MIT header naming Kazuhiko Arase:

```bash
wc -l web/vendor/qrcode.js && head -5 web/vendor/qrcode.js
```

- [ ] **Step 2: Write the test runner page**

`web/test.html`:

```html
<!doctype html>
<html>
<head><meta charset="utf-8"><title>DSTK tests</title>
<style>
  body { font: 14px/1.5 ui-monospace, monospace; padding: 2rem; }
  .pass { color: #197f3d; } .fail { color: #c22; font-weight: bold; }
  #summary { font-size: 1.2rem; margin-bottom: 1rem; }
</style></head>
<body>
  <div id="summary">running…</div>
  <div id="results"></div>
  <script src="vendor/qrcode.js"></script>
  <script src="parse.js"></script>
  <script src="payload.js"></script>
  <script src="test.js"></script>
</body>
</html>
```

`parse.js` and `payload.js` do not exist yet; a missing script is a silent 404 in the browser and
later tasks create them. Leave the tags in place.

- [ ] **Step 3: Write the harness and one self-test**

`web/test.js`:

```js
// Minimal runner. No framework, deliberately: the page has no build step and
// no package manager, and a test harness that needed either would defeat that.
(function () {
  const results = [];
  let failures = 0;

  window.test = function (name, fn) {
    try { fn(); results.push({ name, ok: true }); }
    catch (e) { failures++; results.push({ name, ok: false, msg: e.message }); }
  };

  window.assertEqual = function (actual, expected, what) {
    if (actual !== expected) {
      throw new Error(`${what || ''} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
  };

  window.assertDeepEqual = function (actual, expected, what) {
    const a = JSON.stringify(actual), e = JSON.stringify(expected);
    if (a !== e) throw new Error(`${what || ''} expected ${e}, got ${a}`);
  };

  window.assertThrows = function (fn, what) {
    let threw = false;
    try { fn(); } catch (e) { threw = true; }
    if (!threw) throw new Error(`${what || ''} expected a throw, got none`);
  };

  window.reportResults = function () {
    document.getElementById('summary').textContent =
      failures === 0 ? `✅ all ${results.length} passed` : `❌ ${failures} of ${results.length} failed`;
    document.getElementById('summary').className = failures === 0 ? 'pass' : 'fail';
    document.getElementById('results').innerHTML = results
      .map(r => `<div class="${r.ok ? 'pass' : 'fail'}">${r.ok ? '✓' : '✗'} ${r.name}${r.msg ? ' — ' + r.msg : ''}</div>`)
      .join('');
  };
})();

test('the harness itself reports failures', function () {
  let caught = false;
  try { assertEqual(1, 2, 'deliberate'); } catch (e) { caught = true; }
  assertEqual(caught, true, 'assertEqual must throw on mismatch');
});

test('vendored QR encoder loaded and encodes', function () {
  const q = qrcode(0, 'M');
  q.addData('DSTK1', 'Byte');
  q.make();
  assertEqual(q.getModuleCount() > 0, true, 'module count');
});
```

Append `reportResults();` as the **last line of the file** in every later task that adds tests —
it must run after all `test(...)` calls.

- [ ] **Step 4: Run the tests**

```bash
open web/test.html
```

Expected: **✅ all 2 passed**.

The runner works from `file://` because everything is a classic script. Only the corpus test in
Task 3 needs a server; that task says so.

- [ ] **Step 5: Write the README**

`web/README.md`:

````markdown
# Discord Stickers — desktop companion

Gathers Discord and 7TV emoji on a computer and emits a `DSTK1` payload for the
iPhone app to import.

## Use it

Open `index.html` in a browser. That's it — no build, no server, no install.

## Tests

Most tests run from `file://`:

```
open test.html
```

The corpus parity test needs `fetch`, which `file://` blocks, so for the full suite:

```
python3 -m http.server 8000
open http://localhost:8000/test.html
```

## Layout

| File | Does |
|---|---|
| `parse.js` | pure text → emoji records |
| `sevenTV.js` | the only file that hits the network |
| `payload.js` | pure records → `DSTK1` → byte-sized chunks |
| `app.js` | all DOM and all state |
| `vendor/qrcode.js` | MIT, by Kazuhiko Arase — vendored verbatim, never edit |
````

- [ ] **Step 6: Commit**

```bash
git add web/
git commit -m "feat: scaffold desktop companion page with vendored QR encoder"
```

---

### Task 2: Discord markup parsing

**Files:**
- Create: `web/parse.js`, `web/corpus.json`
- Modify: `web/test.js`

**Interfaces:**
- Produces: `DSTK.parse.discordMarkup(text) -> [record]`

- [ ] **Step 1: Write the shared corpus**

`web/corpus.json`. Both this page and the Swift suite are checked against it, so it is data only
— no comments, no trailing commas.

```json
[
  { "why": "one static emoji",
    "input": "hello <:67:1481800758532903104> world",
    "expect": [{ "id": "1481800758532903104", "name": "67", "animated": false }] },

  { "why": "animated marker",
    "input": "<a:catJAM:1095953169969860649>",
    "expect": [{ "id": "1095953169969860649", "name": "catJAM", "animated": true }] },

  { "why": "duplicate ids collapse to the first occurrence",
    "input": "<:a:111> <:b:111>",
    "expect": [{ "id": "111", "name": "a", "animated": false }] },

  { "why": "original left-to-right order is preserved",
    "input": "<:third:3> <:first:1> <:second:2>",
    "expect": [
      { "id": "3", "name": "third", "animated": false },
      { "id": "1", "name": "first", "animated": false },
      { "id": "2", "name": "second", "animated": false }] },

  { "why": "underscores and digits are legal name characters",
    "input": "<:pepe_Hands2:999>",
    "expect": [{ "id": "999", "name": "pepe_Hands2", "animated": false }] },

  { "why": "a hyphen is not a legal name character, so this is not markup",
    "input": "<:not-valid:123>",
    "expect": [] },

  { "why": "a non-numeric id is not markup",
    "input": "<:name:abc>",
    "expect": [] },

  { "why": "no markup at all",
    "input": "just some ordinary text",
    "expect": [] },

  { "why": "markup embedded in surrounding punctuation still matches",
    "input": "(<:x:5>)!",
    "expect": [{ "id": "5", "name": "x", "animated": false }] },

  { "why": "static and animated mixed, both kept, order preserved",
    "input": "<:s:10><a:m:20><:t:30>",
    "expect": [
      { "id": "10", "name": "s", "animated": false },
      { "id": "20", "name": "m", "animated": true },
      { "id": "30", "name": "t", "animated": false }] }
]
```

- [ ] **Step 2: Write the failing tests**

Append to `web/test.js`, **above** the `reportResults();` line:

```js
test('discordMarkup: single static emoji', function () {
  assertDeepEqual(DSTK.parse.discordMarkup('hi <:67:1481800758532903104>'),
    [{ id: '1481800758532903104', name: '67', source: 'd', animated: false }]);
});

test('discordMarkup: animated marker sets animated', function () {
  assertDeepEqual(DSTK.parse.discordMarkup('<a:catJAM:1095953169969860649>'),
    [{ id: '1095953169969860649', name: 'catJAM', source: 'd', animated: true }]);
});

test('discordMarkup: duplicate ids collapse, first wins', function () {
  const r = DSTK.parse.discordMarkup('<:a:111> <:b:111>');
  assertEqual(r.length, 1, 'length');
  assertEqual(r[0].name, 'a', 'first occurrence wins');
});

test('discordMarkup: order preserved, not sorted', function () {
  const r = DSTK.parse.discordMarkup('<:third:3> <:first:1> <:second:2>');
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
  const r = DSTK.parse.discordMarkup('<:a:1><a:b:2>');
  assertEqual(r.every(function (e) { return e.source === 'd'; }), true, 'all source d');
});
```

- [ ] **Step 2b: Run to verify they fail**

`open web/test.html` → expect failures reading `DSTK is not defined`.

- [ ] **Step 3: Implement**

`web/parse.js`:

```js
// Pure text-to-record parsing. No network, no DOM, no state.
window.DSTK = window.DSTK || {};
DSTK.parse = (function () {

  // Character-for-character the pattern in EmojiMarkupParser.swift. The two
  // implementations are checked against the same corpus.json by both suites;
  // changing one without the other breaks CorpusParityTests.
  const MARKUP = /<(a)?:([A-Za-z0-9_]+):(\d+)>/g;

  function discordMarkup(text) {
    const seen = Object.create(null);
    const out = [];
    let m;
    MARKUP.lastIndex = 0;   // /g regexes carry state between calls
    while ((m = MARKUP.exec(text)) !== null) {
      const id = m[3];
      if (seen[id]) continue;
      seen[id] = true;
      out.push({ id: id, name: m[2], source: 'd', animated: m[1] === 'a' });
    }
    return out;
  }

  return { discordMarkup: discordMarkup };
})();
```

`MARKUP.lastIndex = 0` is not defensive noise: a `/g` regex remembers where it stopped, so
without the reset the *second* call to `discordMarkup` would start mid-string and silently miss
early matches. It only shows up on the second call, which is exactly the kind of bug a
single-call test suite never sees.

- [ ] **Step 4: Run to verify they pass**

`open web/test.html` → expect **✅ all 10 passed**.

- [ ] **Step 5: Prove the order test can fail**

Temporarily change `out.push(...)` to `out.unshift(...)`. Re-run: *order preserved, not sorted*
must go red. Restore the line and confirm green again.

A test that cannot fail is worse than no test — it reports safety it never checked. This project
has already shipped one (`testRestorePreservesFavoriteOrder` passed against an already-sorted
fixture).

- [ ] **Step 6: Commit**

```bash
git add web/parse.js web/corpus.json web/test.js
git commit -m "feat: parse Discord markup on the page, matching the iOS parser"
```

---

### Task 3: Corpus parity between the two parsers

The spec requires the two implementations to agree. This task makes disagreement fail a build
rather than surface as a user-visible difference between what the page shows and what the phone
imports.

**Files:**
- Modify: `web/test.js`
- Create: `DiscordStickers/StickerKitTests/CorpusParityTests.swift`

**Interfaces:**
- Consumes: `web/corpus.json`, `DSTK.parse.discordMarkup`, `EmojiMarkupParser.parse`

- [ ] **Step 1: Write the JS corpus test**

Append to `web/test.js` above `reportResults();`. It is async, so it drives the report itself.

```js
// Runs the shared corpus through the page's parser. Needs fetch, which file://
// blocks -- see README for the one-line server. Skips loudly rather than
// silently passing when the corpus cannot be loaded.
(function () {
  fetch('corpus.json')
    .then(function (r) { return r.json(); })
    .then(function (cases) {
      cases.forEach(function (c) {
        test('corpus: ' + c.why, function () {
          const got = DSTK.parse.discordMarkup(c.input).map(function (e) {
            return { id: e.id, name: e.name, animated: e.animated };
          });
          assertDeepEqual(got, c.expect);
        });
      });
    })
    .catch(function (e) {
      test('corpus: LOADED', function () {
        throw new Error('could not load corpus.json (' + e.message + ') — run from a server, see README');
      });
    })
    .then(reportResults);
})();
```

Remove the standalone `reportResults();` line — this chain now owns reporting, and calling it
twice would render the results block before the async cases land.

- [ ] **Step 2: Run and verify**

```bash
cd web && python3 -m http.server 8000 &
open http://localhost:8000/test.html
```

Expected: all previous tests plus 10 `corpus:` tests, green.

Then check the guard works — `open web/test.html` directly from disk must show
**corpus: LOADED** in red, not a silent green. A missing corpus that reports success is the
failure mode this catch block exists to prevent.

- [ ] **Step 3: Write the Swift side**

`DiscordStickers/StickerKitTests/CorpusParityTests.swift`:

```swift
import XCTest
@testable import StickerKit

/// Runs `web/corpus.json` through `EmojiMarkupParser`, the same corpus the
/// page's `test.js` runs through its own parser. Two implementations of one
/// grammar drift silently otherwise: the page would show emoji the phone then
/// refuses to import, with nothing anywhere reporting a problem.
final class CorpusParityTests: XCTestCase {

    private struct Case: Decodable {
        let why: String
        let input: String
        let expect: [Expected]
    }

    private struct Expected: Decodable {
        let id: String
        let name: String
        let animated: Bool
    }

    /// Located from `#filePath` rather than a bundle resource: the corpus is
    /// shared with the web page and lives outside any target, so copying it
    /// into the test bundle would create a second copy free to drift from the
    /// one the page actually reads.
    private func corpusURL() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StickerKitTests
            .deletingLastPathComponent()   // DiscordStickers
            .deletingLastPathComponent()   // repo root
        dir.appendPathComponent("web/corpus.json")
        return dir
    }

    func testParserMatchesSharedCorpus() throws {
        let url = try corpusURL()
        let data = try Data(contentsOf: url)
        let cases = try JSONDecoder().decode([Case].self, from: data)

        XCTAssertGreaterThan(cases.count, 5,
                             "corpus looks truncated — parity would pass vacuously")

        for c in cases {
            let got = EmojiMarkupParser.parse(c.input)
            XCTAssertEqual(got.count, c.expect.count, "case: \(c.why)")
            guard got.count == c.expect.count else { continue }
            for (actual, expected) in zip(got, c.expect) {
                XCTAssertEqual(actual.id, expected.id, "case: \(c.why)")
                XCTAssertEqual(actual.name, expected.name, "case: \(c.why)")
                XCTAssertEqual(actual.isAnimated, expected.animated, "case: \(c.why)")
            }
        }
    }
}
```

The `count > 5` assertion is load-bearing: if the file path ever breaks and `decode` yields an
empty array, a `for` loop over nothing passes with flying colours. This is the same
vacuous-pass hazard as an empty test.

- [ ] **Step 4: Run the Swift suite**

```bash
cd "/Users/jonathan/Projects/discord stickers for iphone" && \
xcodebuild test -scheme StickerKit -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | tail -20
```

Expected: 174 tests, all passing.

- [ ] **Step 5: Prove parity actually binds**

Add a deliberately divergent case to `corpus.json` — `{"why":"drift probe","input":"<:x:1>","expect":[]}`.
Run **both** suites. Both must go red. Remove it and confirm both green again.

If only one goes red, the two suites are not reading the same file and the parity check is
theatre.

- [ ] **Step 6: Commit**

```bash
git add web/test.js DiscordStickers/StickerKitTests/CorpusParityTests.swift web/corpus.json
git commit -m "test: check both markup parsers against one shared corpus"
```

---

### Task 4: Raw ids and links

**Files:**
- Modify: `web/parse.js`, `web/test.js`

**Interfaces:**
- Produces: `DSTK.parse.rawLines(text) -> { records: [record], rejected: [{ line, reason }] }`

Returns rejections rather than dropping them: a user who pastes 40 lines and gets 38 emoji needs
to know which two failed and why. Silently importing 38 is the worse outcome.

- [ ] **Step 1: Write the failing tests**

Append above the corpus block in `web/test.js`:

```js
test('rawLines: bare id becomes a static Discord record', function () {
  const r = DSTK.parse.rawLines('1481800758532903104');
  assertDeepEqual(r.records,
    [{ id: '1481800758532903104', name: '1481800758532903104', source: 'd', animated: false }]);
  assertEqual(r.rejected.length, 0, 'no rejections');
});

test('rawLines: Discord CDN url, png is static', function () {
  const r = DSTK.parse.rawLines('https://cdn.discordapp.com/emojis/123.png');
  assertEqual(r.records[0].id, '123', 'id');
  assertEqual(r.records[0].animated, false, 'static');
  assertEqual(r.records[0].source, 'd', 'source');
});

test('rawLines: Discord CDN url, gif is animated', function () {
  const r = DSTK.parse.rawLines('https://cdn.discordapp.com/emojis/123.gif');
  assertEqual(r.records[0].animated, true, 'animated');
});

test('rawLines: query parameters are ignored', function () {
  const r = DSTK.parse.rawLines('https://cdn.discordapp.com/emojis/456.gif?size=96&quality=lossless');
  assertEqual(r.records[0].id, '456', 'id');
  assertEqual(r.records[0].animated, true, 'animated');
});

test('rawLines: 7TV url with gif is animated 7TV', function () {
  const r = DSTK.parse.rawLines('https://cdn.7tv.app/emote/01FCY771D800007PQ2DF3GDTN6/4x.gif');
  assertDeepEqual(r.records, [{
    id: '01FCY771D800007PQ2DF3GDTN6', name: '01FCY771D800007PQ2DF3GDTN6',
    source: '7', animated: true }]);
});

test('rawLines: 7TV url with webp is static 7TV', function () {
  const r = DSTK.parse.rawLines('https://cdn.7tv.app/emote/01GAZ199Z8000FEWHS6AT5QZV0/4x.webp');
  assertEqual(r.records[0].animated, false, 'static');
  assertEqual(r.records[0].source, '7', 'source');
});

test('rawLines: 7TV url with no usable extension is REJECTED, not guessed', function () {
  const r = DSTK.parse.rawLines('https://cdn.7tv.app/emote/01GAZ199Z8000FEWHS6AT5QZV0');
  assertEqual(r.records.length, 0, 'nothing imported');
  assertEqual(r.rejected.length, 1, 'one rejection');
});

test('rawLines: junk line is rejected but the batch survives', function () {
  const r = DSTK.parse.rawLines('not an id\n123\nalso junk');
  assertEqual(r.records.length, 1, 'the good line still imported');
  assertEqual(r.records[0].id, '123', 'id');
  assertEqual(r.rejected.length, 2, 'two rejections');
});

test('rawLines: blank lines and whitespace are skipped silently', function () {
  const r = DSTK.parse.rawLines('\n  \n123\n\n   \n');
  assertEqual(r.records.length, 1, 'one record');
  assertEqual(r.rejected.length, 0, 'blank lines are not rejections');
});

test('rawLines: duplicate ids collapse across mixed shapes', function () {
  const r = DSTK.parse.rawLines('123\nhttps://cdn.discordapp.com/emojis/123.gif');
  assertEqual(r.records.length, 1, 'deduped');
  assertEqual(r.records[0].animated, false, 'first occurrence wins');
});
```

The 7TV rejection test is the important one. A bare 7TV id cannot be defaulted to static the way
a Discord id can: Discord answers 415 for a wrong format and the phone retries, but 7TV returns
**200 with a valid still image**, so a wrong guess there is permanent and silent.

- [ ] **Step 1b: Run to verify they fail**

`open web/test.html` → expect `DSTK.parse.rawLines is not a function`.

- [ ] **Step 2: Implement**

Add inside the `DSTK.parse` IIFE in `web/parse.js`, before the `return`:

```js
  const DISCORD_URL = /cdn\.discordapp\.com\/emojis\/(\d+)(?:\.(\w+))?/i;
  const SEVENTV_URL = /cdn\.7tv\.app\/emote\/([A-Za-z0-9]+)(?:\/\w+\.(\w+))?/i;
  const BARE_ID     = /^\d+$/;

  function rawLines(text) {
    const seen = Object.create(null);
    const records = [];
    const rejected = [];

    text.split(/\r?\n/).forEach(function (raw) {
      const line = raw.trim();
      if (!line) return;                       // blank is not a rejection

      let rec = null, reason = null, m;

      if ((m = line.match(DISCORD_URL))) {
        rec = { id: m[1], name: m[1], source: 'd', animated: (m[2] || '').toLowerCase() === 'gif' };

      } else if ((m = line.match(SEVENTV_URL))) {
        const ext = (m[2] || '').toLowerCase();
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
```

and extend the return to `{ discordMarkup: discordMarkup, rawLines: rawLines }`.

- [ ] **Step 3: Run to verify they pass**

`open web/test.html` → all green.

- [ ] **Step 4: Prove the 7TV rejection binds**

Temporarily add an `else { rec = { id: m[1], name: m[1], source: '7', animated: false }; }` to the
7TV branch. The *no usable extension is REJECTED* test must go red. Restore.

- [ ] **Step 5: Commit**

```bash
git add web/parse.js web/test.js
git commit -m "feat: accept raw emoji ids and CDN links"
```

---

### Task 5: 7TV set fetching

**Files:**
- Create: `web/sevenTV.js`
- Modify: `web/test.js`, `web/test.html`

**Interfaces:**
- Produces: `DSTK.sevenTV.setIdFrom(input) -> string|null` (pure) and `DSTK.sevenTV.fetchSet(setId) -> Promise<[record]>`

Split deliberately: id extraction is pure and fully testable offline; only `fetchSet` touches the
network. A live-API test would make the suite fail when 7TV has a bad day.

Verified live 2026-08-08: `GET https://7tv.io/v3/emote-sets/<id>` returns `{ emotes: [{ id, name,
data: { animated } }] }`, and the API reflects the `Origin` header — including `null` — so this
works from `file://` and from GitHub Pages with no proxy.

- [ ] **Step 1: Write the failing tests**

```js
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
  const api = { emotes: [
    { id: 'AAA', name: 'RainTime', data: { animated: true } },
    { id: 'BBB', name: 'peepoHappy', data: { animated: false } }] };
  assertDeepEqual(DSTK.sevenTV.normalizeEmotes(api), [
    { id: 'AAA', name: 'RainTime', source: '7', animated: true },
    { id: 'BBB', name: 'peepoHappy', source: '7', animated: false }]);
});

test('normalizeEmotes: a missing data block is treated as static, not dropped', function () {
  const r = DSTK.sevenTV.normalizeEmotes({ emotes: [{ id: 'C', name: 'x' }] });
  assertEqual(r.length, 1, 'kept');
  assertEqual(r[0].animated, false, 'defaults static');
});

test('normalizeEmotes: an absent emotes array yields empty, not a throw', function () {
  assertDeepEqual(DSTK.sevenTV.normalizeEmotes({}), []);
});
```

- [ ] **Step 2: Run to verify they fail**

Add `<script src="sevenTV.js"></script>` to `test.html` after `parse.js`. Re-run → failures.

- [ ] **Step 3: Implement**

`web/sevenTV.js`:

```js
// The only unit here that performs network I/O. Everything it returns is a
// plain record array, so the UI and payload layers never learn the 7TV API.
window.DSTK = window.DSTK || {};
DSTK.sevenTV = (function () {

  const API = 'https://7tv.io/v3/emote-sets/';

  // ULIDs: 26 characters, Crockford base32. 'global' is the documented
  // well-known set and is accepted verbatim.
  const ID = /([A-HJKMNP-TV-Z0-9]{26})/i;

  function setIdFrom(input) {
    const s = (input || '').trim();
    if (!s) return null;
    if (s.toLowerCase() === 'global') return 'global';
    const m = s.match(ID);
    return m ? m[1] : null;
  }

  function normalizeEmotes(json) {
    const emotes = (json && json.emotes) || [];
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
```

- [ ] **Step 4: Run to verify they pass**

`open web/test.html` → all green.

- [ ] **Step 5: Confirm against the live API once, by hand**

Not a suite test — the suite must not depend on 7TV being up.

```bash
curl -s "https://7tv.io/v3/emote-sets/global" | head -c 300
```

Confirm the response has `emotes` with `id`, `name`, and `data.animated`. If the shape has
changed, `normalizeEmotes` is what needs updating and the tests above encode the old shape.

- [ ] **Step 6: Commit**

```bash
git add web/sevenTV.js web/test.js web/test.html
git commit -m "feat: resolve 7TV emote sets"
```

---

### Task 6: Payload building and byte-driven chunking

**Files:**
- Create: `web/payload.js`
- Modify: `web/test.js`

**Interfaces:**
- Produces: `DSTK.payload.tagFor(record)`, `DSTK.payload.build(records)`, `DSTK.payload.byteLength(str)`, `DSTK.payload.chunk(records)`
- Consumes: nothing. Pure.

- [ ] **Step 1: Write the failing tests**

```js
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
  const long = 'x'.repeat(100);
  const out = DSTK.payload.build([{ id: '1', name: long, source: 'd', animated: false }]);
  assertEqual(out.split(' ')[2].length, 64, 'name length');
});

test('build: newlines inside a name are stripped, not emitted', function () {
  const out = DSTK.payload.build([{ id: '1', name: 'two\nlines', source: 'd', animated: false }]);
  assertEqual(out.split('\n').length, 2, 'still one record line');
});

test('byteLength: counts UTF-8 bytes, not characters', function () {
  assertEqual(DSTK.payload.byteLength('abc'), 3, 'ascii');
  assertEqual(DSTK.payload.byteLength('é'), 2, 'two-byte char');
  assertEqual(DSTK.payload.byteLength('🎉'), 4, 'four-byte char');
});

test('chunk: a small selection is a single chunk', function () {
  const recs = [{ id: '1', name: 'a', source: 'd', animated: false }];
  assertEqual(DSTK.payload.chunk(recs).length, 1);
});

test('chunk: every chunk carries the header', function () {
  const recs = [];
  for (let i = 0; i < 200; i++) recs.push({ id: '10000000000000000' + i, name: 'name' + i, source: 'd', animated: false });
  const chunks = DSTK.payload.chunk(recs);
  assertEqual(chunks.length > 1, true, 'did split');
  assertEqual(chunks.every(function (c) { return c.indexOf('DSTK1\n') === 0; }), true, 'all headed');
});

test('chunk: chunks reassemble to exactly the input, nothing lost or duplicated', function () {
  const recs = [];
  for (let i = 0; i < 200; i++) recs.push({ id: '10000000000000000' + i, name: 'name' + i, source: 'd', animated: false });
  const ids = [];
  DSTK.payload.chunk(recs).forEach(function (c) {
    c.split('\n').slice(1).forEach(function (line) { ids.push(line.split(' ')[1]); });
  });
  assertDeepEqual(ids, recs.map(function (r) { return r.id; }));
});

test('chunk: no chunk exceeds the byte budget', function () {
  const recs = [];
  for (let i = 0; i < 300; i++) recs.push({ id: '10000000000000000' + i, name: 'nm' + i, source: 'd', animated: false });
  DSTK.payload.chunk(recs).forEach(function (c) {
    assertEqual(DSTK.payload.byteLength(c) <= DSTK.payload.MAX_CHUNK_BYTES, true,
      'chunk of ' + DSTK.payload.byteLength(c) + ' bytes');
  });
});

test('chunk: SPLITS BY BYTES NOT COUNT — same count, longer ids, more chunks', function () {
  const n = 60;
  const shortIds = [], longIds = [];
  for (let i = 0; i < n; i++) {
    shortIds.push({ id: '14818007585329' + i, name: 'nm', source: 'd', animated: false });
    longIds.push({ id: '01FCY771D800007PQ2DF3GDT' + i, name: 'nm', source: '7', animated: true });
  }
  const a = DSTK.payload.chunk(shortIds).length;
  const b = DSTK.payload.chunk(longIds).length;
  assertEqual(b > a, true, 'longer 7TV ids must need more chunks (' + a + ' vs ' + b + ')');
});

test('chunk: every emitted chunk actually encodes as a QR', function () {
  const recs = [];
  for (let i = 0; i < 250; i++) recs.push({ id: '01FCY771D800007PQ2DF3GDT' + i, name: 'emote' + i, source: '7', animated: true });
  DSTK.payload.chunk(recs).forEach(function (c, i) {
    const q = qrcode(0, DSTK.payload.QR_EC);
    q.addData(c, 'Byte');
    q.make();                       // throws if the chunk does not fit
    assertEqual(q.getModuleCount() > 0, true, 'chunk ' + i);
  });
});

test('chunk: a single record too large to ever fit still yields a chunk', function () {
  const huge = { id: '1', name: 'x'.repeat(64), source: 'd', animated: false };
  assertEqual(DSTK.payload.chunk([huge]).length, 1, 'not an infinite loop');
});
```

The *SPLITS BY BYTES NOT COUNT* and *actually encodes as a QR* tests are the two that matter.
The first fails against any count-based implementation; the second is the only check that
survives a future change to `MAX_CHUNK_BYTES`, because it asks the encoder instead of comparing
against a hard-coded number.

- [ ] **Step 1b: Run to verify they fail**

- [ ] **Step 2: Implement**

`web/payload.js`:

```js
// Pure. Records in, DSTK1 text out, then split into QR-sized pieces.
window.DSTK = window.DSTK || {};
DSTK.payload = (function () {

  const HEADER = 'DSTK1';
  const MAX_NAME = 64;          // StickerLimits.maxStickerNameLength
  const MAX_EMOJI = 500;        // StickerLimits.maxPayloadEmoji

  // Measured against the vendored encoder: error correction M tops out at 2331
  // bytes, which needs a 177-module code -- the densest QR that exists, and
  // genuinely hard to scan off a laptop screen. 1200 bytes lands at 133 modules
  // and reads first time. The binding constraint here is the camera, not
  // capacity.
  const MAX_CHUNK_BYTES = 1200;
  const QR_EC = 'M';

  const encoder = new TextEncoder();
  function byteLength(s) { return encoder.encode(s).length; }

  function tagFor(r) { return r.source + (r.animated ? 'a' : ''); }

  function lineFor(r) {
    // The name runs to end of line, so a newline inside one would forge an
    // extra record. Spaces are fine and deliberately preserved -- the parser
    // splits on the first two only.
    const name = String(r.name).replace(/[\r\n]+/g, ' ').trim().slice(0, MAX_NAME);
    return tagFor(r) + ' ' + r.id + ' ' + name;
  }

  function build(records) {
    const lines = records.slice(0, MAX_EMOJI).map(lineFor);
    return lines.length ? HEADER + '\n' + lines.join('\n') : HEADER;
  }

  function chunk(records) {
    const capped = records.slice(0, MAX_EMOJI);
    if (!capped.length) return [HEADER];

    const chunks = [];
    let current = [];
    let size = byteLength(HEADER);

    capped.forEach(function (r) {
      const line = lineFor(r);
      const cost = byteLength(line) + 1;              // + the newline
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
```

- [ ] **Step 3: Run to verify they pass**

- [ ] **Step 4: Prove the byte-driven test binds**

Replace the size check with a count check — `if (current.length >= 35)` — and re-run. *SPLITS BY
BYTES NOT COUNT* must go red while the reassembly tests stay green. That combination is the
proof: the implementation still loses nothing, it just chunks on the wrong axis, which is
exactly the bug the spec calls out. Restore.

- [ ] **Step 5: Commit**

```bash
git add web/payload.js web/test.js
git commit -m "feat: build DSTK1 payloads and chunk them by byte budget"
```

---

### Task 7: The page — inputs, picker, and output

**Files:**
- Create: `web/index.html`, `web/app.js`

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write `index.html`**

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Discord Stickers — build a sticker set</title>
<style>
  :root { --bg:#fff; --fg:#1a1a1a; --muted:#666; --line:#ddd; --accent:#5865f2; --bad:#c22; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#16171a; --fg:#e8e8e8; --muted:#999; --line:#333; --accent:#7983f5; }
  }
  * { box-sizing: border-box; }
  body { margin:0; padding:2rem 1rem 4rem; background:var(--bg); color:var(--fg);
         font:16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
         max-width:900px; margin-inline:auto; }
  h1 { font-size:1.5rem; margin:0 0 .25rem; }
  h2 { font-size:1rem; margin:2rem 0 .5rem; }
  p.sub { color:var(--muted); margin:0 0 2rem; }
  textarea, input[type=text] { width:100%; padding:.6rem; font:inherit; font-size:.9rem;
    background:var(--bg); color:var(--fg); border:1px solid var(--line); border-radius:6px; }
  textarea { min-height:5rem; resize:vertical; font-family:ui-monospace, monospace; }
  button { font:inherit; padding:.5rem 1rem; border:1px solid var(--line); border-radius:6px;
    background:var(--bg); color:var(--fg); cursor:pointer; }
  button.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
  .row { display:flex; gap:.5rem; align-items:center; flex-wrap:wrap; }
  #grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(150px,1fr));
          gap:.5rem; margin-top:1rem; }
  .cell { display:flex; align-items:center; gap:.5rem; padding:.4rem;
          border:1px solid var(--line); border-radius:6px; }
  .cell img { width:32px; height:32px; object-fit:contain; flex:none; }
  .cell input[type=text] { border:none; padding:.2rem; font-size:.85rem; }
  .cell input[type=text]:focus { outline:1px solid var(--accent); border-radius:3px; }
  #out { width:100%; min-height:8rem; font-family:ui-monospace, monospace; font-size:.8rem; }
  #qrs { display:flex; gap:1rem; flex-wrap:wrap; margin-top:1rem; }
  .qr { text-align:center; font-size:.8rem; color:var(--muted); }
  .qr img { display:block; width:240px; height:240px; image-rendering:pixelated;
            background:#fff; padding:8px; border-radius:6px; }
  .muted { color:var(--muted); font-size:.85rem; }
  .bad { color:var(--bad); font-size:.85rem; }
</style>
</head>
<body>
<h1>Build a sticker set</h1>
<p class="sub">Gather emoji here, then send the result to your phone. Nothing is uploaded or
stored — this page only handles names and links, and your phone fetches the images itself.</p>

<h2>1 · Paste Discord messages</h2>
<textarea id="in-markup" placeholder="Paste a Discord message containing custom emoji…"></textarea>
<div id="msg-markup" class="muted"></div>

<h2>2 · A 7TV emote set</h2>
<div class="row">
  <input type="text" id="in-7tv" placeholder="7TV emote-set id or URL, or 'global'">
  <button id="btn-7tv">Load</button>
</div>
<div id="msg-7tv" class="muted"></div>

<h2>3 · Emoji ids or image links</h2>
<textarea id="in-raw" placeholder="One per line — an emoji id, a cdn.discordapp.com link, or a cdn.7tv.app link"></textarea>
<div id="msg-raw" class="muted"></div>

<h2>Selected <span id="count" class="muted"></span></h2>
<div class="row">
  <button id="btn-all">Select all</button>
  <button id="btn-none">Select none</button>
  <button id="btn-clear">Clear everything</button>
</div>
<div id="grid"></div>

<h2>Send it to your phone</h2>
<div class="row">
  <button id="btn-copy" class="primary">Copy payload</button>
  <span id="size" class="muted"></span>
  <span id="msg-copy" class="muted"></span>
</div>
<textarea id="out" readonly></textarea>
<div id="qrs"></div>

<script src="vendor/qrcode.js"></script>
<script src="parse.js"></script>
<script src="sevenTV.js"></script>
<script src="payload.js"></script>
<script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Write `app.js`**

```js
// The only file that touches the DOM or holds mutable state. Everything it
// calls is pure or returns a promise of plain records.
(function () {
  'use strict';

  // One ordered list, keyed by id. Merging rather than replacing is what lets
  // the three inputs combine: typing in one must never discard another's finds,
  // or a user who pastes markup and then loads a 7TV set silently loses half.
  const found = [];                      // [{ id, name, source, animated, selected }]
  const byId = Object.create(null);

  const $ = function (id) { return document.getElementById(id); };

  function merge(records) {
    let added = 0;
    records.forEach(function (r) {
      if (byId[r.id]) return;
      const entry = { id: r.id, name: r.name, source: r.source,
                      animated: r.animated, selected: true };
      byId[r.id] = entry;
      found.push(entry);
      added++;
    });
    if (added) render();
    return added;
  }

  function thumbURL(e) {
    return e.source === '7'
      ? 'https://cdn.7tv.app/emote/' + e.id + '/1x.' + (e.animated ? 'gif' : 'webp')
      : 'https://cdn.discordapp.com/emojis/' + e.id + '.' + (e.animated ? 'gif' : 'png') + '?size=44';
  }

  function selected() {
    return found.filter(function (e) { return e.selected; });
  }

  function renderGrid() {
    const grid = $('grid');
    grid.textContent = '';
    found.forEach(function (e) {
      const cell = document.createElement('div');
      cell.className = 'cell';

      const box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = e.selected;
      box.addEventListener('change', function () { e.selected = box.checked; renderOutput(); });

      const img = document.createElement('img');
      img.src = thumbURL(e);
      img.alt = '';
      img.loading = 'lazy';
      // A thumbnail that fails to load says nothing about whether the phone's
      // fetch will succeed, so the emote stays selectable either way.
      img.addEventListener('error', function () { img.style.visibility = 'hidden'; });

      const name = document.createElement('input');
      name.type = 'text';
      name.value = e.name;
      name.addEventListener('input', function () { e.name = name.value; renderOutput(); });

      cell.appendChild(box); cell.appendChild(img); cell.appendChild(name);
      grid.appendChild(cell);
    });
  }

  function renderOutput() {
    const sel = selected();
    $('count').textContent = sel.length ? sel.length + ' of ' + found.length : '';

    if (!sel.length) {
      $('out').value = '';
      $('out').placeholder = 'Select at least one emoji.';
      $('qrs').textContent = '';
      $('size').textContent = '';
      $('btn-copy').disabled = true;
      return;
    }

    $('btn-copy').disabled = false;
    const chunks = DSTK.payload.chunk(sel);
    const text = DSTK.payload.build(sel);
    $('out').value = text;

    // Byte size is shown, not just the count, because chunking is byte-driven:
    // a user seeing four QR codes for 60 emoji has no way to understand why
    // from a count alone, since 60 7TV emotes and 60 Discord emoji chunk
    // differently.
    $('size').textContent = DSTK.payload.byteLength(text) + ' bytes'
      + (chunks.length > 1 ? ' · ' + chunks.length + ' QR codes' : '');

    const qrs = $('qrs');
    qrs.textContent = '';
    chunks.forEach(function (c, i) {
      const wrap = document.createElement('div');
      wrap.className = 'qr';
      const q = qrcode(0, DSTK.payload.QR_EC);
      q.addData(c, 'Byte');
      q.make();
      wrap.innerHTML = q.createImgTag(4, 0);
      const label = document.createElement('div');
      label.textContent = chunks.length > 1 ? (i + 1) + ' of ' + chunks.length : 'scan me';
      wrap.appendChild(label);
      qrs.appendChild(wrap);
    });
  }

  function render() { renderGrid(); renderOutput(); }

  $('in-markup').addEventListener('input', function () {
    const records = DSTK.parse.discordMarkup(this.value);
    merge(records);
    const msg = $('msg-markup');
    // Same wording as the app's, deliberately: someone who hits this on the
    // page and then again on the phone should recognise one message, not
    // wonder whether they are two different problems.
    if (this.value.trim() && !records.length) {
      msg.className = 'bad';
      msg.textContent = 'No Discord emoji found in that text.';
    } else { msg.className = 'muted'; msg.textContent = ''; }
  });

  $('in-raw').addEventListener('input', function () {
    const r = DSTK.parse.rawLines(this.value);
    merge(r.records);
    const msg = $('msg-raw');
    // Rejections are shown, never swallowed: a user who pastes 40 lines and
    // gets 38 emoji needs to know which two failed and why.
    if (r.rejected.length) {
      msg.className = 'bad';
      msg.textContent = r.rejected.length + " line(s) skipped — " + r.rejected[0].reason;
    } else { msg.className = 'muted'; msg.textContent = ''; }
  });

  $('btn-7tv').addEventListener('click', function () {
    const msg = $('msg-7tv');
    const setId = DSTK.sevenTV.setIdFrom($('in-7tv').value);
    if (!setId) {
      msg.className = 'bad';
      msg.textContent = "That doesn't look like a 7TV emote set id or URL.";
      return;
    }
    msg.className = 'muted';
    msg.textContent = 'Loading…';
    DSTK.sevenTV.fetchSet(setId).then(function (records) {
      const added = merge(records);
      msg.className = 'muted';
      msg.textContent = records.length
        ? 'Found ' + records.length + ' emotes (' + added + ' new).'
        : 'No 7TV emotes found for that set.';
    }).catch(function (e) {
      msg.className = 'bad';
      msg.textContent = e.message;
    });
  });

  $('btn-all').addEventListener('click', function () {
    found.forEach(function (e) { e.selected = true; }); render();
  });
  $('btn-none').addEventListener('click', function () {
    found.forEach(function (e) { e.selected = false; }); render();
  });
  $('btn-clear').addEventListener('click', function () {
    found.length = 0;
    Object.keys(byId).forEach(function (k) { delete byId[k]; });
    $('in-markup').value = ''; $('in-raw').value = '';
    $('msg-raw').textContent = ''; $('msg-7tv').textContent = '';
    render();
  });

  $('btn-copy').addEventListener('click', function () {
    const text = $('out').value;
    const done = function () {
      $('msg-copy').textContent = 'Copied — paste it in the app.';
      setTimeout(function () { $('msg-copy').textContent = ''; }, 3000);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {
        $('out').select(); document.execCommand('copy'); done();
      });
    } else {
      // file:// and older browsers have no async clipboard API.
      $('out').select(); document.execCommand('copy'); done();
    }
  });

  render();
})();
```

- [ ] **Step 3: Verify in a browser**

```bash
open web/index.html
```

Check each:
1. Paste `hello <:67:1481800758532903104> and <a:catJAM:1095953169969860649>` into box 1 → two cells with thumbnails, output shows `d 1481800758532903104 67` and `da 1095953169969860649 catJAM`.
2. Type `global` in box 2, click Load → ~45 emotes appear with thumbnails, the animated ones moving.
3. Paste `1481800758532903104` into box 3 → the cell count does **not** change, because box 1 already added that id. This is the cross-input dedupe working.
4. Paste `https://cdn.7tv.app/emote/01GAZ199Z8000FEWHS6AT5QZV0` (no extension) into box 3 → red line saying it needs the full URL.
5. Type `hello there` into box 1 alone → *"No Discord emoji found in that text."*
6. Edit a name inline → payload updates live, and **focus stays in the field you are typing in**. If the caret jumps, `renderGrid` is being called on name input when only `renderOutput` should be.
7. Uncheck a box → payload, byte count and QR count all update.
8. With the global set loaded, confirm **more than one QR** appears, labelled *1 of N*, and that the byte count is shown.
9. Click Copy payload → confirmation appears. Test this from `file://`, where `navigator.clipboard` may be unavailable and the `execCommand` fallback is what actually runs.

- [ ] **Step 4: Commit**

```bash
git add web/index.html web/app.js
git commit -m "feat: the desktop companion page"
```

---

### Task 8: End-to-end verification and publish

**Files:**
- Modify: `web/README.md`
- Create: `docs/superpowers/plans/web-page-verification.md`

- [ ] **Step 1: The round trip that matters**

Generate a payload on the page containing **at least one of each tag** — `d`, `da`, `7`, `7a`.
Copy it. Get it onto the phone (Universal Clipboard, or mail it to yourself). Paste it in the app
with **Paste Emoji**.

Confirm: all four import, the `da` and `7a` ones **animate**, the `d` and `7` ones are static and
sharp.

This is the only check that exercises the producer and consumer against each other. Everything
before it tests one half in isolation.

- [ ] **Step 2: The multi-chunk round trip**

Load the 7TV `global` set, select all, and confirm several QR codes render. Scan each with the
iPhone camera, copying each into the app in turn.

Confirm the final sticker count equals the number selected — nothing dropped at a chunk boundary,
nothing duplicated. Chunk boundaries are where a silent loss would hide.

- [ ] **Step 3: Record results**

Write `docs/superpowers/plans/web-page-verification.md` with a line per check, and note the emoji
count and chunk count actually used.

- [ ] **Step 4: Note how to publish**

Append to `web/README.md`:

```markdown
## Publishing

GitHub → repo Settings → Pages → Source: `main`, folder `/web`. The page is static
with no build step, so it deploys as-is and is live at
`https://<user>.github.io/<repo>/`.

The repo is currently private; Pages on a private repo needs a paid plan, so make
the repo public first — the page contains no secrets and stores nothing.
```

- [ ] **Step 5: Commit**

```bash
git add web/README.md docs/superpowers/plans/web-page-verification.md
git commit -m "docs: record web page end-to-end verification"
```

---

## Deferred

- **BetterTTV and FrankerFaceZ.** The payload's source tag makes them additive.
- **A short-link service** so QR codes carry a URL instead of data. Needs a server; ruled out by the spec.
- **Reordering emoji by dragging.** The phone sorts by add time and the app has Favorites; ordering here would be a second, conflicting notion of order.
