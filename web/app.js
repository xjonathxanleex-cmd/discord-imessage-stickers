// The only file that touches the DOM or holds mutable state. Everything it
// calls is pure or returns a promise of plain records.
(function () {
  'use strict';

  // One ordered list, keyed by id. Merging rather than replacing is what lets
  // the three inputs combine: typing in one must never discard another's finds,
  // or a user who pastes markup and then loads a 7TV set silently loses half.
  var found = [];                      // [{ id, name, source, animated, selected }]
  var byId = Object.create(null);

  function $(id) { return document.getElementById(id); }

  function merge(records) {
    var added = 0;
    records.forEach(function (r) {
      if (byId[r.id]) return;
      var entry = { id: r.id, name: r.name, source: r.source,
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
    var grid = $('grid');
    grid.textContent = '';
    found.forEach(function (e) {
      var cell = document.createElement('div');
      cell.className = 'cell';

      var box = document.createElement('input');
      box.type = 'checkbox';
      box.checked = e.selected;
      box.addEventListener('change', function () { e.selected = box.checked; renderOutput(); });

      var img = document.createElement('img');
      img.src = thumbURL(e);
      img.alt = '';
      img.loading = 'lazy';
      // A thumbnail that fails to load says nothing about whether the phone's
      // fetch will succeed, so the emote stays selectable either way.
      img.addEventListener('error', function () { img.style.visibility = 'hidden'; });

      var name = document.createElement('input');
      name.type = 'text';
      name.value = e.name;
      // renderOutput, never render: rebuilding the grid here would destroy the
      // very field being typed in and drop the caret on every keystroke.
      name.addEventListener('input', function () { e.name = name.value; renderOutput(); });

      cell.appendChild(box); cell.appendChild(img); cell.appendChild(name);
      grid.appendChild(cell);
    });
  }

  function renderOutput() {
    var sel = selected();
    $('count').textContent = found.length ? sel.length + ' of ' + found.length : '';

    if (!sel.length) {
      $('out').value = '';
      $('out').placeholder = 'Select at least one emoji.';
      $('qrs').textContent = '';
      $('size').textContent = '';
      $('btn-copy').disabled = true;
      return;
    }

    $('btn-copy').disabled = false;
    var chunks = DSTK.payload.chunk(sel);
    var text = DSTK.payload.build(sel);
    $('out').value = text;

    // Byte size is shown, not just the count, because chunking is byte-driven:
    // a user seeing four QR codes for 60 emoji has no way to understand why
    // from a count alone, since 60 7TV emotes and 60 Discord emoji chunk
    // differently.
    $('size').textContent = DSTK.payload.byteLength(text) + ' bytes' +
      (chunks.length > 1 ? ' · ' + chunks.length + ' QR codes' : '');

    var qrs = $('qrs');
    qrs.textContent = '';
    chunks.forEach(function (c, i) {
      var wrap = document.createElement('div');
      wrap.className = 'qr';

      var q = qrcode(0, DSTK.payload.QR_EC);
      q.addData(c, 'Byte');
      q.make();

      // createDataURL + a built element rather than createImgTag + innerHTML:
      // no markup string is ever parsed, so there is no injection surface here
      // at all, however trusted the source looks.
      var img = document.createElement('img');
      img.src = q.createDataURL(4, 0);
      img.alt = 'QR code ' + (i + 1);

      var label = document.createElement('div');
      label.textContent = chunks.length > 1 ? (i + 1) + ' of ' + chunks.length : 'scan me';

      wrap.appendChild(img); wrap.appendChild(label);
      qrs.appendChild(wrap);
    });
  }

  function render() { renderGrid(); renderOutput(); }

  $('in-markup').addEventListener('input', function () {
    var records = DSTK.parse.discordMarkup(this.value);
    merge(records);
    var msg = $('msg-markup');
    // Same wording as the app's, deliberately: someone who hits this on the
    // page and then again on the phone should recognise one message, not
    // wonder whether they are two different problems.
    if (this.value.trim() && !records.length) {
      msg.className = 'bad';
      msg.textContent = 'No Discord emoji found in that text.';
    } else { msg.className = 'muted'; msg.textContent = ''; }
  });

  $('in-raw').addEventListener('input', function () {
    var r = DSTK.parse.rawLines(this.value);
    merge(r.records);
    var msg = $('msg-raw');
    // Rejections are shown, never swallowed: a user who pastes 40 lines and
    // gets 38 emoji needs to know which two failed and why.
    //
    // Every distinct reason, not just the first. A 7TV link missing its
    // extension and a line of junk fail for unrelated reasons, and showing only
    // reason[0] tells the user to fix the wrong thing -- the 7TV line reads as
    // "not an emoji id or a CDN link", which it plainly is.
    if (r.rejected.length) {
      var reasons = [];
      r.rejected.forEach(function (x) {
        if (reasons.indexOf(x.reason) === -1) reasons.push(x.reason);
      });
      msg.className = 'bad';
      msg.textContent = r.rejected.length + ' line(s) skipped — ' + reasons.join('; ');
    } else { msg.className = 'muted'; msg.textContent = ''; }
  });

  $('btn-7tv').addEventListener('click', function () {
    var msg = $('msg-7tv');
    var setId = DSTK.sevenTV.setIdFrom($('in-7tv').value);
    if (!setId) {
      msg.className = 'bad';
      msg.textContent = "That doesn't look like a 7TV emote set id or URL.";
      return;
    }
    msg.className = 'muted';
    msg.textContent = 'Loading…';
    DSTK.sevenTV.fetchSet(setId).then(function (records) {
      var added = merge(records);
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
    $('msg-markup').textContent = '';
    render();
  });

  $('btn-copy').addEventListener('click', function () {
    var text = $('out').value;
    var done = function () {
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
