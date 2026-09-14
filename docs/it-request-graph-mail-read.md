# IT request: Azure app registration for Buildertrend notification ingest

**Requested by:** Jordan Hefner, Director of Operations, Van Buskirk Homes
**Purpose:** Let an automated job read Buildertrend notification emails from one folder in Jordan's mailbox and load them into our operations database (Supabase). Read-only. One mailbox. No sending, no other users.

## What we need

An Entra ID (Azure AD) **app registration** in the Van Buskirk Companies tenant with **application** (not delegated) permission to read mail, scoped so it can only touch Jordan's mailbox.

| Item | Value |
|---|---|
| App name | `VBH Buildertrend Bridge` |
| Supported account types | Single tenant (this organization only) |
| Redirect URI | none (daemon / client-credentials flow) |
| API permission | Microsoft Graph → **Application** → `Mail.Read` |
| Admin consent | Required (application permission) |
| Credential | Client secret, 24-month expiry (we'll calendar the rotation) |
| Mailbox scope | Application access policy restricting the app to `jordan.hefner@vanbuskirkco.com` only (steps below) |

## Steps (Entra admin)

1. **Entra admin center → App registrations → New registration.** Name `VBH Buildertrend Bridge`, single tenant, no redirect URI. Register.
2. On the app's **Overview**, note the **Application (client) ID** and **Directory (tenant) ID**.
3. **API permissions → Add a permission → Microsoft Graph → Application permissions → Mail → `Mail.Read`.** Add, then **Grant admin consent for Van Buskirk Companies**.
4. **Certificates & secrets → New client secret.** Description `supabase-edge-fn`, expiry 24 months. Copy the **Value** now — it's shown once.
5. **Restrict the app to one mailbox** (Exchange Online PowerShell, as an Exchange admin):

   ```powershell
   Connect-ExchangeOnline
   # A mail-enabled security group containing only Jordan's mailbox
   New-DistributionGroup -Name "VBH Buildertrend Bridge Scope" -Type Security -Members jordan.hefner@vanbuskirkco.com
   # Bind the app to that group. Replace <APP-CLIENT-ID>.
   New-ApplicationAccessPolicy -AppId <APP-CLIENT-ID> -PolicyScopeGroupId "VBH Buildertrend Bridge Scope" -AccessRight RestrictAccess -Description "Buildertrend bridge: read Jordan's mailbox only"
   # Verify (expect AccessCheckResult: Granted for Jordan, Denied for anyone else)
   Test-ApplicationAccessPolicy -Identity jordan.hefner@vanbuskirkco.com -AppId <APP-CLIENT-ID>
   Test-ApplicationAccessPolicy -Identity someone.else@vanbuskirkco.com -AppId <APP-CLIENT-ID>
   ```

   The policy takes up to 30 minutes to apply.

## Hand back to Jordan (securely — not by email in plain text)

- Tenant ID
- Application (client) ID
- Client secret value
- Secret expiry date

These will be stored only as Supabase Edge Function secrets. They will not be committed to any repository.

## What the job does with it

Every 15 minutes it calls `GET /users/jordan.hefner@vanbuskirkco.com/mailFolders/{Buildertrend}/messages` filtered to messages received since the last run, stores each one (subject, body, sender, Message-ID, received time) in our database, and parses the templated Buildertrend notifications into structured records for the weekly production meeting. It never modifies, moves, or sends mail.

## Why not delegated permissions or a shared mailbox?

Delegated permissions would tie the job to a user sign-in session and break when the password or MFA changes. A shared mailbox would work but requires re-pointing Buildertrend's notification recipients; the folder rule in Jordan's mailbox is already in place. If IT prefers a dedicated shared mailbox (`buildertrend@vanbuskirkco.com`) instead, that's fine — the same app registration and access policy apply, scoped to that mailbox.
