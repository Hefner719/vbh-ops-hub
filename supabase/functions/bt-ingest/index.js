/* ═══════════════════════════════════════════════════════════════════════════
   VBH · Buildertrend bridge · ingest function · build bt-ingest-v1

   Polls one Outlook folder through Microsoft Graph and hands every new message
   to bt_ingest_email() in Supabase. The plpgsql trigger does the parsing.

   Modes (query string):
     ?mode=poll       (default) fetch new mail since the last successful run
     ?mode=backfill&days=90     re-fetch the last N days; duplicates are skipped
     ?mode=rerender   rebuild body_text from stored body_html for every Graph row,
                      then re-run the parser. Use after changing htmlToText().

   Secrets (Supabase → Edge Functions → Secrets):
     GRAPH_TENANT_ID, GRAPH_CLIENT_ID, GRAPH_CLIENT_SECRET   from IT (docs/it-request-graph-mail-read.md)
     GRAPH_MAILBOX        jordan.hefner@vanbuskirkco.com
     GRAPH_FOLDER         Buildertrend          (display name; searched at any depth)
     BT_CRON_SECRET       random string; the pg_cron trigger sends it as x-cron-secret
   Provided automatically: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
   ═══════════════════════════════════════════════════════════════════════════ */

const BUILD = 'bt-ingest-v1';
const GRAPH = 'https://graph.microsoft.com/v1.0';
const PAGE_SIZE = 50;
const DEFAULT_BACKFILL_DAYS = 30;
const OVERLAP_HOURS = 6; // re-read a little history each poll; dedupe makes it free

const env = (k, required = true) => {
  const v = Deno.env.get(k);
  if (required && !v) throw new Error(`Missing secret ${k}`);
  return v || '';
};

/* ── Supabase (service role, PostgREST) ────────────────────────────────── */
const SB_URL = env('SUPABASE_URL');
const SB_KEY = env('SUPABASE_SERVICE_ROLE_KEY');
const sbHeaders = (extra = {}) => ({
  apikey: SB_KEY,
  Authorization: `Bearer ${SB_KEY}`,
  'Content-Type': 'application/json',
  ...extra,
});

async function sbRpc(fn, args) {
  const r = await fetch(`${SB_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers: sbHeaders(), body: JSON.stringify(args) });
  if (!r.ok) throw new Error(`rpc ${fn} → ${r.status} ${await r.text()}`);
  return r.json();
}
async function sbSelect(path) {
  const r = await fetch(`${SB_URL}/rest/v1/${path}`, { headers: sbHeaders() });
  if (!r.ok) throw new Error(`select ${path} → ${r.status} ${await r.text()}`);
  return r.json();
}
async function sbInsert(table, row) {
  const r = await fetch(`${SB_URL}/rest/v1/${table}`, {
    method: 'POST', headers: sbHeaders({ Prefer: 'return=representation' }), body: JSON.stringify(row),
  });
  if (!r.ok) throw new Error(`insert ${table} → ${r.status} ${await r.text()}`);
  return (await r.json())[0];
}
async function sbPatch(table, filter, patch) {
  const r = await fetch(`${SB_URL}/rest/v1/${table}?${filter}`, {
    method: 'PATCH', headers: sbHeaders({ Prefer: 'return=minimal' }), body: JSON.stringify(patch),
  });
  if (!r.ok) throw new Error(`patch ${table} → ${r.status} ${await r.text()}`);
}

/* ── Microsoft Graph ───────────────────────────────────────────────────── */
async function graphToken() {
  const body = new URLSearchParams({
    client_id: env('GRAPH_CLIENT_ID'),
    client_secret: env('GRAPH_CLIENT_SECRET'),
    scope: 'https://graph.microsoft.com/.default',
    grant_type: 'client_credentials',
  });
  const r = await fetch(`https://login.microsoftonline.com/${env('GRAPH_TENANT_ID')}/oauth2/v2.0/token`, {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body,
  });
  if (!r.ok) throw new Error(`token → ${r.status} ${await r.text()}`);
  return (await r.json()).access_token;
}

async function graphGet(token, url) {
  const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new Error(`graph ${url} → ${r.status} ${await r.text()}`);
  return r.json();
}

/* Find a mail folder by display name at any depth. Buildertrend mail is
   usually filed under Inbox/Buildertrend, but a rule could put it anywhere. */
async function findFolder(token, mailbox, name) {
  const want = name.trim().toLowerCase();
  const base = `${GRAPH}/users/${encodeURIComponent(mailbox)}/mailFolders`;
  const queue = [`${base}?$top=100&$select=id,displayName,childFolderCount`];
  while (queue.length) {
    const page = await graphGet(token, queue.shift());
    for (const f of page.value || []) {
      if ((f.displayName || '').trim().toLowerCase() === want) return f;
      if (f.childFolderCount > 0) queue.push(`${base}/${f.id}/childFolders?$top=100&$select=id,displayName,childFolderCount`);
    }
    if (page['@odata.nextLink']) queue.push(page['@odata.nextLink']);
  }
  throw new Error(`Mail folder "${name}" not found in ${mailbox}`);
}

async function* messagesSince(token, mailbox, folderId, sinceISO) {
  const select = 'id,internetMessageId,subject,receivedDateTime,from,toRecipients,body';
  let url = `${GRAPH}/users/${encodeURIComponent(mailbox)}/mailFolders/${folderId}/messages` +
    `?$filter=receivedDateTime ge ${sinceISO}&$orderby=receivedDateTime asc&$top=${PAGE_SIZE}&$select=${select}`;
  while (url) {
    const page = await graphGet(token, url);
    for (const m of page.value || []) yield m;
    url = page['@odata.nextLink'] || null;
  }
}

/* ── HTML → text, Outlook-style ────────────────────────────────────────────
   The parser was built on Outlook's plain-text rendering, where links come
   out as `Anchor text <https://…>`, table cells become tabs and rows become
   lines. Reproduce that so Graph mail parses identically to the samples. */
const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ldquo: '“', rdquo: '”',
  lsquo: '‘', rsquo: '’', mdash: '—', ndash: '–', hellip: '…', copy: '©', bull: '•' };
function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) => {
    if (e[0] === '#') {
      const code = e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : m;
    }
    return ENTITIES[e.toLowerCase()] ?? m;
  });
}
export function htmlToText(html) {
  let s = String(html || '');
  s = s.replace(/<!--[\s\S]*?-->/g, '');
  s = s.replace(/<(script|style|head|title)\b[\s\S]*?<\/\1>/gi, '');
  // <a href="U">inner</a> → "inner <U>"  (inner may be an image → just " <U>")
  s = s.replace(/<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi, (m, h1, h2, h3, inner) => {
    const href = decodeEntities(h1 ?? h2 ?? h3 ?? '').trim();
    const text = inner.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
    if (!href || /^(mailto:|#)/i.test(href)) return text;
    return (text ? text + ' ' : ' ') + '<' + href + '> ';
  });
  s = s.replace(/<img\b[^>]*>/gi, '');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<\/(td|th)>/gi, '\t');
  s = s.replace(/<\/(tr|p|div|li|h[1-6]|table|blockquote|section|article|header|footer)>/gi, '\n');
  s = s.replace(/<(p|div|li|h[1-6]|tr|table|blockquote|hr)\b[^>]*>/gi, '\n');
  s = s.replace(/<[^>]+>/g, '');
  s = decodeEntities(s);
  s = s.replace(/\r/g, '');
  s = s.replace(/[ \t]+\n/g, '\n');           // trailing whitespace per line (tabs from cells stay inside lines)
  s = s.replace(/\n{3,}/g, '\n\n');
  return s.trim();
}

/* ── Ingest one message ─────────────────────────────────────────────────── */
async function ingest(m, source) {
  const messageId = m.internetMessageId || `graph:${m.id}`;
  const isHtml = (m.body?.contentType || '').toLowerCase() === 'html';
  const bodyHtml = isHtml ? m.body.content : null;
  const bodyText = isHtml ? htmlToText(m.body.content) : String(m.body?.content || '');
  return sbRpc('bt_ingest_email', {
    p_secret: null,                              // service role: secret check is skipped
    p_message_id: messageId,
    p_subject: m.subject || '',
    p_body_text: bodyText,
    p_body_html: bodyHtml,
    p_received_at: m.receivedDateTime || null,
    p_from_address: m.from?.emailAddress?.address || null,
    p_from_name: m.from?.emailAddress?.name || null,
    p_to_address: (m.toRecipients || []).map((r) => r.emailAddress?.address).filter(Boolean).join(', ') || null,
    p_source: source,
  });
}

/* ── Modes ─────────────────────────────────────────────────────────────── */
async function runPoll({ backfillDays = null } = {}) {
  const source = 'graph';
  const run = await sbInsert('bt_ingest_runs', { source });
  const tally = { fetched: 0, inserted: 0, duplicates: 0, errors: 0, notes: [] };
  try {
    let since;
    if (backfillDays) {
      since = new Date(Date.now() - backfillDays * 86400000);
    } else {
      const last = await sbSelect(`bt_emails?select=received_at&source=eq.${source}&order=received_at.desc.nullslast&limit=1`);
      since = last[0]?.received_at
        ? new Date(new Date(last[0].received_at).getTime() - OVERLAP_HOURS * 3600000)
        : new Date(Date.now() - DEFAULT_BACKFILL_DAYS * 86400000);
    }
    const sinceISO = since.toISOString().replace(/\.\d{3}Z$/, 'Z');

    const token = await graphToken();
    const mailbox = env('GRAPH_MAILBOX');
    const folder = await findFolder(token, mailbox, env('GRAPH_FOLDER', false) || 'Buildertrend');

    for await (const m of messagesSince(token, mailbox, folder.id, sinceISO)) {
      tally.fetched++;
      try {
        const outcome = await ingest(m, source);
        if (outcome === 'inserted') tally.inserted++; else tally.duplicates++;
      } catch (e) {
        tally.errors++;
        tally.notes.push({ message_id: m.internetMessageId || m.id, subject: m.subject, outcome: 'error', error: String(e.message || e) });
      }
    }

    // Parser outcomes for what this run inserted.
    const counts = await sbSelect(`bt_emails?select=parse_status&source=eq.${source}&ingested_at=gte.${encodeURIComponent(run.started_at)}`);
    const parsedOk = counts.filter((r) => r.parse_status === 'ok').length;
    const unclassified = counts.filter((r) => r.parse_status === 'unclassified').length;
    const parseErrors = counts.filter((r) => r.parse_status === 'error').length;

    await sbPatch('bt_ingest_runs', `id=eq.${run.id}`, {
      finished_at: new Date().toISOString(),
      fetched: tally.fetched, inserted: tally.inserted, duplicates: tally.duplicates,
      parsed_ok: parsedOk, unclassified, errors: tally.errors + parseErrors,
      notes: tally.notes.concat({ since: sinceISO, folder: folder.displayName, build: BUILD }),
    });
    return { run_id: run.id, since: sinceISO, ...tally, parsed_ok: parsedOk, unclassified, parse_errors: parseErrors, notes: undefined };
  } catch (e) {
    await sbPatch('bt_ingest_runs', `id=eq.${run.id}`, {
      finished_at: new Date().toISOString(), fetched: tally.fetched, inserted: tally.inserted,
      duplicates: tally.duplicates, errors: tally.errors + 1, error: String(e.message || e), notes: tally.notes,
    });
    throw e;
  }
}

/* Rebuild body_text from stored HTML for every Graph-sourced email, then reparse. */
async function runRerender() {
  const rows = await sbSelect('bt_emails?select=id,body_html&source=eq.graph&body_html=not.is.null&order=id');
  let updated = 0;
  for (const r of rows) {
    await sbPatch('bt_emails', `id=eq.${r.id}`, { body_text: htmlToText(r.body_html) });
    updated++;
  }
  const counts = await sbRpc('bt_reparse_all', {});
  return { rerendered: updated, events_by_type: counts };
}

/* ── HTTP entry ─────────────────────────────────────────────────────────── */
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const want = env('BT_CRON_SECRET', false);
  if (want && req.headers.get('x-cron-secret') !== want) {
    return new Response(JSON.stringify({ error: 'forbidden' }), { status: 403, headers: { 'Content-Type': 'application/json' } });
  }
  const mode = url.searchParams.get('mode') || 'poll';
  const started = Date.now();
  try {
    let result;
    if (mode === 'rerender') result = await runRerender();
    else if (mode === 'backfill') result = await runPoll({ backfillDays: Math.max(1, parseInt(url.searchParams.get('days') || '90', 10)) });
    else result = await runPoll();
    return new Response(JSON.stringify({ ok: true, build: BUILD, mode, ms: Date.now() - started, ...result }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    console.error(`[${BUILD}] ${mode} failed:`, e);
    return new Response(JSON.stringify({ ok: false, build: BUILD, mode, error: String(e.message || e) }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    });
  }
});
