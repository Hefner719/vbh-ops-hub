<#
  vbh-invite.ps1 - generate sign-in links for the team, without sending email.

  WHY THIS EXISTS
  Supabase's built-in mailer is capped at 2 messages an hour and the cap cannot
  be raised without configuring custom SMTP. Onboarding sixteen people through
  it would be slow and fragile - one person retrying burns the quota for
  everyone else.

  Supabase's admin API can mint the same sign-in link the email would have
  contained. This prints them so they can be handed out however suits: Teams,
  text, or in person. Nothing is emailed, no new vendor, nothing for IT to
  approve.

  Each link signs that person in on the device they open it with, creates their
  profile on first use (roles come from vbh_role_seed), and is good for seven
  days. Treat one like a password for that person: it is single use, but anyone
  holding it before they do can use it.

    tools\vbh-invite.ps1                       # everyone on the roster
    tools\vbh-invite.ps1 -Only sydney.vanwell@vanbuskirkco.com
    tools\vbh-invite.ps1 -Pending              # only those who have not signed in
    tools\vbh-invite.ps1 -Csv invites.csv      # write to a file instead

  Needs %USERPROFILE%\.vbh\supabase_service_key.txt.
#>
param(
  [string[]]$Only,
  [switch]$Pending,
  [string]$Csv,
  [string]$ProjectRef = 'bppirsahciuxrqzitfxa',
  [string]$RedirectTo = 'https://vbchomes.net/hub'
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$keyFile = Join-Path $env:USERPROFILE '.vbh\supabase_service_key.txt'
if (-not (Test-Path $keyFile)) { throw "Missing $keyFile - run the key setup first." }
$svc = (Get-Content $keyFile -Raw).Trim()
$base = "https://$ProjectRef.supabase.co"
$hdr  = @{ apikey = $svc; Authorization = "Bearer $svc"; 'Content-Type' = 'application/json' }

# Who to invite: the roster, optionally narrowed.
$rosterUri = "$base/rest/v1/vbh_role_seed?select=email,full_name,role&order=role,email"
$roster = Invoke-RestMethod -Uri $rosterUri -Headers $hdr
if ($Only) { $roster = $roster | Where-Object { $Only -contains $_.email } }

if ($Pending) {
  $have = Invoke-RestMethod -Uri "$base/rest/v1/profiles?select=email" -Headers $hdr
  $signedIn = @($have | ForEach-Object { $_.email.ToLower() })
  $roster = $roster | Where-Object { $signedIn -notcontains $_.email.ToLower() }
}
if (-not $roster) { Write-Host 'Nobody to invite.' -ForegroundColor Yellow; exit 0 }

$out = @()
foreach ($p in $roster) {
  $body = @{
    type     = 'magiclink'
    email    = $p.email
    options  = @{ redirect_to = $RedirectTo }
  } | ConvertTo-Json -Depth 5
  try {
    $r = Invoke-RestMethod -Method Post -Uri "$base/auth/v1/admin/generate_link" `
           -Headers $hdr -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $link = $r.action_link
    if (-not $link -and $r.properties) { $link = $r.properties.action_link }
    $out += [pscustomobject]@{
      Name  = $p.full_name
      Email = $p.email
      Role  = $p.role
      Link  = $link
    }
  } catch {
    $detail = ''
    if ($_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
    $out += [pscustomobject]@{ Name = $p.full_name; Email = $p.email; Role = $p.role; Link = "FAILED: $detail" }
  }
}

if ($Csv) {
  $out | Export-Csv -Path $Csv -NoTypeInformation -Encoding UTF8
  Write-Host "Wrote $($out.Count) invite(s) to $Csv" -ForegroundColor Green
  Write-Host 'That file contains working sign-in links. Delete it once they are handed out.' -ForegroundColor Yellow
} else {
  Write-Host ''
  foreach ($o in $out) {
    Write-Host ("{0} ({1}, {2})" -f $o.Name, $o.Email, $o.Role) -ForegroundColor Cyan
    Write-Host ("  " + $o.Link)
    Write-Host ''
  }
  Write-Host "$($out.Count) link(s). Each is good for 7 days and signs that person in on the device they open it with." -ForegroundColor Green
  Write-Host 'Treat one like that person''s password until they use it.' -ForegroundColor Yellow
}
