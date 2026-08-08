# Discord Stickers — desktop companion

Gathers Discord and 7TV emoji on a computer and emits a `DSTK1` payload for the
iPhone app to import.

## Use it

Open `index.html` in a browser. That's it — no build, no server, no install.

Three inputs, all optional and combinable:

1. **Paste a Discord message** containing custom emoji
2. **A 7TV emote-set** id or URL (try `global`)
3. **Raw ids or CDN links**, one per line — for an emoji id you found anywhere

Pick what you want, rename anything inline, then copy the payload or scan the QR
codes with your phone.

## Tests

Two runners over the same `test.js`:

```
node run-tests.js       # headless, has an exit code
open test.html          # browser
```

The browser runner needs a server for the corpus test, because `file://` blocks
`fetch`:

```
python3 -m http.server 8000
open http://localhost:8000/test.html
```

Opened straight from disk it reports **corpus: LOADED** in red rather than
silently skipping — a corpus that fails to load must never look like a pass.

## Layout

| File | Does |
|---|---|
| `parse.js` | pure text → emoji records |
| `sevenTV.js` | the only file that hits the network |
| `payload.js` | pure records → `DSTK1` → byte-sized chunks |
| `app.js` | all DOM and all state |
| `corpus.json` | Discord markup cases, shared with the Swift suite |
| `vendor/qrcode.js` | MIT, by Kazuhiko Arase — vendored verbatim, never edit |

## Two things worth knowing before changing anything

**The markup regex is duplicated on purpose.** `parse.js` and
`EmojiMarkupParser.swift` implement the same grammar in two languages. Both are
checked against `corpus.json`, so changing one alone turns `CorpusParityTests`
red. That is the point — otherwise the page would show emoji the phone then
refuses to import, with nothing anywhere reporting a problem.

**Chunking is by bytes, never by emoji count.** 7TV ids are 26 characters and
Discord ids are 18–19, so the same *number* of emoji can be 2.7 KB or 3.4 KB.
Counting would overflow a QR on 7TV-heavy sets. There is a test named
`SPLITS BY BYTES NOT COUNT` that fails against any count-based implementation.

## Publishing

GitHub → repo Settings → Pages → Source: `main`, folder `/web`. The page is
static with no build step, so it deploys as-is at
`https://<user>.github.io/<repo>/`.

The repo is private; Pages on a private repo needs a paid plan, so make it public
first — the page contains no secrets and stores nothing.
