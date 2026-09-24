# Runbook: moving the hub to real accounts

## Why

The shared password is checked in the browser. It hides the interface, not the
data: the Supabase anon key is published in `vbh-config.js`, and until Phase B
runs, that key can read, change and delete `projects`, `leads`, `meetings`,
`project_updates` and `assets`. Real accounts plus row-level security are what
actually close that.

## Where it stands (2026-09-24)

- **Phase A is live.** Migration 006 applied; `shell-v2` deployed. The gate
  offers a magic-link sign-in and still accepts the shared password. Nothing
  breaks; signing in changes nothing yet.
- **Phase B is written but NOT applied** (`007_auth_lockdown.sql`), with
  `008_auth_rollback.sql` to reverse it.

## Blocker: email delivery

Supabase's built-in mailer allows **2 emails per hour** and no custom SMTP is
configured. That cannot onboard 16 people, and it is the same gap that stops
the scheduled Friday digest. Pick a sender before rolling out:

| Option | Gets us | Cost |
|---|---|---|
| Resend | magic links + digest + work-order mail | free to 3k/mo; verify vbchomes.net by DNS |
| Microsoft 365 SMTP | same, no new vendor | needs IT to allow SMTP AUTH or an app password |
| Ask IT for Graph `Mail.Send` | digest only — Supabase Auth needs SMTP, not Graph | another IT request |

Recommended: Resend. DNS records go on vbchomes.net, which we control through
Netlify, and one sender covers all three needs.

Once chosen, set it under Supabase → Authentication → Emails → SMTP, then raise
`rate_limit_email_sent`.

## Rollout, in order

1. Configure custom SMTP (above). Send yourself a magic link and confirm it
   arrives and signs you in.
2. Tell the team: "Go to vbchomes.net, enter your work email, click the link we
   send. The shared password still works until Friday."
3. Watch who has signed in:
   ```
   tools\sb-sql.ps1 -Query "select s.email, (p.id is not null) as signed_in, p.role, p.active from vbh_role_seed s left join profiles p on lower(p.email)=lower(s.email) order by signed_in, s.email"
   ```
4. When everyone shows `signed_in = true`, run Phase B:
   ```
   tools\sb-sql.ps1 -File supabase\migrations\007_auth_lockdown.sql
   ```
   It prints the resulting policies — read them. Expect anon INSERT only on
   `leads` and `work_orders` (the two public forms), everything else
   authenticated.
5. Verify the anon key is now inert:
   ```
   curl "https://bppirsahciuxrqzitfxa.supabase.co/rest/v1/projects?select=*&limit=1" -H "apikey: <anon key>"
   ```
   Expect `[]`, not rows.
6. Remove the shared password: delete `PASSWORD` from `vbh-config.js` and the
   fallback branch in `vbh-shell.js`. Until this step the password still opens
   the interface — though after Phase B it shows empty pages, because the data
   layer no longer trusts it.

If anything goes wrong, `008_auth_rollback.sql` restores the old policies
immediately. It re-opens anonymous access, so treat it as a fallback for the
length of a working day, not a resting state.

## Roles

`owner`, `ops_admin` — read, write, delete · `manager`, `field` — read, write ·
`labor` — read only. Seeded in `vbh_role_seed`; a person keeps their seeded role
when they first sign in. To change someone:

```
tools\sb-sql.ps1 -Query "update profiles set role='manager' where email='x@vanbuskirkco.com'"
tools\sb-sql.ps1 -Query "update vbh_role_seed set role='manager' where email='x@vanbuskirkco.com'"
```

To remove access immediately: `update profiles set active=false where email='…'`.

Only company addresses (`@vanbuskirkco.com`, `@vbclink.com`) are activated
automatically. Anyone else who signs up lands inactive and sees nothing.
