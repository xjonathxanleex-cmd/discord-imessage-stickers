# 7TV API findings — verified 2026-08-08

Measured against the live API before designing. Do not re-derive from assumption.

## The endpoint shape is better than the spec assumed

```
GET https://7tv.io/v3/users/twitch/{twitchNumericId}
GET https://7tv.io/v3/emote-sets/{setId}
GET https://7tv.io/v3/emote-sets/global          # stable, no auth, good for tests
```

`GET /v3/v3` returns 404 — there is no version index; the sub-paths are the API.

The user endpoint embeds the whole emote set, so **one request** yields everything:

```
users/twitch/71092938  ->  { username, emote_set_id, emote_set: { emotes: [...] } }
```

Each emote carries what we need directly:

| Field | Example | Use |
|---|---|---|
| `id` | `01G3WEGZN0000ET2J0MQP5YJ0G` | CDN path |
| `name` | `GAMBA` | sticker name — search works |
| `data.animated` | `true` | **animation is a fact here, not a guess** |
| `data.host.url` | `//cdn.7tv.app/emote/01FCY…` | scheme-relative base |
| `data.host.files[]` | `1x.webp … 4x.avif` | advertised variants |

That `animated` boolean is worth noting: link import has to infer animation from a URL's
file extension, and photo import detects it from bytes. 7TV simply tells us.

## CDN formats, measured on an animated emote

| Variant | Status | Bytes | Type |
|---|---|---|---|
| `4x.webp` | 200 | 572,384 | WebP |
| `4x.avif` | 200 | 143,086 | AVIF image sequence |
| `4x.gif` | 200 | 550,680 | **GIF89a, 156×128** |
| `2x.webp` | 200 | 223,606 | WebP |
| `1x.webp` | 200 | 72,376 | WebP |

Two more measurements, taken specifically to settle whether a wrong `isAnimated` guess
would ever surface as an error the way Discord's does:

| Request | Emote | Status | Bytes |
|---|---|---|---|
| `4x.webp` | **animated** emote | **200** | 572,384 |
| `4x.gif` | **static** emote | **404** | — |

Neither result is a Discord-style 415. An animated emote fetched as `4x.webp` (the "static"
request) returns 200 with a genuinely valid image — just the wrong one, a still frame in
place of motion — so guessing wrong here produces no error at all, only a sticker that quietly
never animates. And "always request `.gif` to be safe" is not a workaround either: `4x.gif` on
a *static* emote 404s outright, which would break every static 7TV import. The only correct
approach is to know `animated` before requesting anything, which is exactly why the transfer
payload's source tag now carries it (`7`/`7a`, `d`/`da` — see the desktop companion design
spec §3) rather than leaving the phone to infer or retry its way to the right format.

Two things follow:

1. **`4x.webp` is 572 KB — over `MSSticker`'s 500 KB limit on the wire.** It does not matter
   directly, since everything is re-encoded through our own processors, but it does mean the
   raw fetch must stay under the byte cap rather than being assumed small.

2. **`.gif` works but is NOT in `host.files`.** The API advertises only webp and avif, yet
   `4x.gif` returns a valid GIF89a. This is the decisive fact for animated emotes: `.gif` is
   guaranteed decodable by `CGImageSource` and is already handled by
   `AnimatedStickerProcessor`, whereas **animated WebP support in ImageIO is unverified on
   this platform**.

   **Design decision:** request `.gif` for animated emotes and `.webp` for static ones. If
   `.gif` ever stops being served, the fallback is animated WebP — which needs a device check
   before it can be relied on, because nothing here proves ImageIO reports more than one frame
   for it.

## What is still unknown

- **Resolving a Twitch *username* to the numeric id** the user endpoint needs. The REST API
  takes an id. A username lookup means either 7TV's GraphQL endpoint or asking the user for an
  emote-set id / URL directly. Asking is simpler and has no undocumented dependency.
- **Whether ImageIO decodes animated WebP as multiple frames.** Avoided entirely by choosing
  `.gif` above; only becomes relevant if that stops working.
