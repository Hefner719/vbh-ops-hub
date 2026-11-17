# Sign-in email templates (shell-v4)

The hub signs people in with a code typed into the gate, not a link. Microsoft's mail scanner
opens every link in an incoming message, and a one-time Supabase link is spent the moment
anything opens it, so the person's own click then fails with "Email link is invalid or has
expired". The link and the code are the **same** one-time token, so the email must carry
**no link at all**: if the scanner opens a link, the code dies with it.

Where: Supabase dashboard → project `bppirsahciuxrqzitfxa` → Authentication → Emails → Templates.
Set **both** templates below. "Confirm signup" goes to someone signing in for the first time
and "Magic Link" to everyone after that.

## Magic Link

Subject:

```
Your VBH Ops Hub sign-in code
```

Body:

```html
<h2 style="font-family:Georgia,serif;color:#1B3564">VBH Ops Hub sign-in</h2>
<p>Type this code into the sign-in screen:</p>
<p style="font-size:30px;font-weight:bold;letter-spacing:8px;color:#1B3564">{{ .Token }}</p>
<p>It expires in one hour. If you didn't ask for it, ignore this email.</p>
```

## Confirm signup

Subject:

```
Your VBH Ops Hub sign-in code
```

Body: the same HTML as Magic Link.

## Check

Leave out `{{ .ConfirmationURL }}`, and any other link, from both templates. Send yourself a
code from the gate at vbchomes.net/hub. The email should show only the code.

Supabase's built-in mailer allows 2 emails an hour across the whole project. That limit stays
until a custom SMTP sender is set up.
