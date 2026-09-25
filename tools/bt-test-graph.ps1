<#
  bt-test-graph.ps1 - preflight the Microsoft Graph setup.

  Four checks, each printing the exact fix when it fails:
    1. Token    - are tenant / client / secret valid?
    2. Consent  - has Mail.Read (Application) been granted?
    3. Mailbox  - does the application access policy allow this mailbox?
    4. Folder   - does the Buildertrend folder exist, and what is in it?

  Reads %USERPROFILE%\.vbh\bt-graph.env. Use -Secret to try a candidate value
  without saving it. Never prints the secret or the access token.

    powershell -ExecutionPolicy Bypass -File tools\bt-test-graph.ps1
    powershell -ExecutionPolicy Bypass -File tools\bt-test-graph.ps1 -Secret '<candidate>'
#>
param([string]$Secret)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$envFile = Join-Path $env:USERPROFILE '.vbh\bt-graph.env'
$cfg = @{}
if (Test-Path $envFile) {
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $cfg[$Matches[1]] = $Matches[2].Trim() }
  }
}
$tenant  = $cfg['GRAPH_TENANT_ID']
$client  = $cfg['GRAPH_CLIENT_ID']
$secret  = if ($Secret) { $Secret.Trim() } else { $cfg['GRAPH_CLIENT_SECRET'] }
$mailbox = if ($cfg['GRAPH_MAILBOX']) { $cfg['GRAPH_MAILBOX'] } else { 'jordan.hefner@vanbuskirkco.com' }
$folder  = if ($cfg['GRAPH_FOLDER'])  { $cfg['GRAPH_FOLDER'] }  else { 'Buildertrend' }

if (-not $tenant) { throw 'No GRAPH_TENANT_ID in the env file.' }
if (-not $client) { throw 'No GRAPH_CLIENT_ID in the env file.' }
if (-not $secret) { throw "No secret. Pass -Secret '<value>' or fill GRAPH_CLIENT_SECRET in $envFile." }

$isGuid = $secret -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
Write-Host ''
Write-Host "Tenant   $tenant"
Write-Host "Client   $client"
Write-Host "Secret   $($secret.Length) chars$(if ($isGuid) { ', GUID-shaped' })"
Write-Host "Mailbox  $mailbox    Folder: $folder"
Write-Host ''

# ── 1 - token ───────────────────────────────────────────────────────────────
Write-Host '1. Requesting a token from Microsoft ...' -NoNewline
$body = @{
  client_id     = $client
  client_secret = $secret
  scope         = 'https://graph.microsoft.com/.default'
  grant_type    = 'client_credentials'
}
try {
  $tok = Invoke-RestMethod -Method Post -Body $body -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"
  $access = $tok.access_token
  Write-Host '  OK' -ForegroundColor Green
} catch {
  $d = ''
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $d = $_.ErrorDetails.Message }
  Write-Host '  FAILED' -ForegroundColor Red
  Write-Host ''
  switch -Regex ($d) {
    'AADSTS7000215' {
      Write-Host '  Invalid client secret (AADSTS7000215).' -ForegroundColor Yellow
      if ($isGuid) {
        Write-Host '  This value is GUID-shaped, so it is the Secret ID rather than the Value.'
        Write-Host '  Azure shows the Value only at creation, so IT must issue a NEW secret'
        Write-Host '  and send the Value column.'
      } else {
        Write-Host '  Check for a truncated paste, a trailing space, or a deleted secret.'
      }
      break
    }
    'AADSTS7000222' { Write-Host '  The client secret has EXPIRED (AADSTS7000222). IT must issue a new one.' -ForegroundColor Yellow; break }
    'AADSTS700016'  { Write-Host '  App not found in this tenant (AADSTS700016). Check the client ID.' -ForegroundColor Yellow; break }
    'AADSTS90002'   { Write-Host '  Tenant not found (AADSTS90002). Check the tenant ID.' -ForegroundColor Yellow; break }
    default         { Write-Host "  $d" -ForegroundColor Yellow }
  }
  Write-Host ''
  exit 1
}

# ── 2 - consent ─────────────────────────────────────────────────────────────
Write-Host '2. Checking granted permissions ...' -NoNewline
$part = ($access -split '\.')[1].Replace('-', '+').Replace('_', '/')
while ($part.Length % 4) { $part += '=' }
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
$roles = @($claims.roles)
if ($roles -contains 'Mail.Read' -or $roles -contains 'Mail.ReadWrite') {
  Write-Host "  OK - $($roles -join ', ')" -ForegroundColor Green
} else {
  Write-Host '  MISSING' -ForegroundColor Red
  $only = if ($roles) { " Token carries only: $($roles -join ', ')." } else { ' Token carries no application roles at all.' }
  Write-Host "  No Mail.Read role.$only" -ForegroundColor Yellow
  Write-Host '  IT must add Microsoft Graph -> APPLICATION permissions -> Mail.Read and click'
  Write-Host '  "Grant admin consent". A Delegated permission will not work for this.'
  Write-Host ''
  exit 1
}

# ── 3 - mailbox ─────────────────────────────────────────────────────────────
$hdr = @{ Authorization = "Bearer $access" }
$base = "https://graph.microsoft.com/v1.0/users/$mailbox"
Write-Host '3. Reading the mailbox ...' -NoNewline
try {
  $null = Invoke-RestMethod -Headers $hdr -Uri "$base/mailFolders/inbox?`$select=id"
  Write-Host '  OK' -ForegroundColor Green
} catch {
  $d = ''
  if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $d = $_.ErrorDetails.Message }
  Write-Host '  FAILED' -ForegroundColor Red
  if ($d -match 'ApplicationAccessPolicy|ErrorAccessDenied') {
    Write-Host '  Blocked by the application access policy.' -ForegroundColor Yellow
    Write-Host '  Either it excludes this mailbox, or it was created recently and has not'
    Write-Host '  propagated yet (allow 30 minutes). Ask IT to run:'
    Write-Host "    Test-ApplicationAccessPolicy -Identity $mailbox -AppId $client"
  } elseif ($d -match 'ResourceNotFound|MailboxNotEnabled') {
    Write-Host "  Mailbox $mailbox not found or not REST-enabled. Check the address." -ForegroundColor Yellow
  } else {
    Write-Host "  $d" -ForegroundColor Yellow
  }
  Write-Host ''
  exit 1
}

# ── 4 - folder ──────────────────────────────────────────────────────────────
Write-Host "4. Locating the '$folder' folder ..." -NoNewline
$want = $folder.Trim().ToLower()
$found = $null
$queue = New-Object System.Collections.Queue
$queue.Enqueue("$base/mailFolders?`$top=100&`$select=id,displayName,childFolderCount,totalItemCount")
while ($queue.Count -gt 0 -and -not $found) {
  $page = Invoke-RestMethod -Headers $hdr -Uri $queue.Dequeue()
  foreach ($f in $page.value) {
    if ($f.displayName.Trim().ToLower() -eq $want) { $found = $f; break }
    if ($f.childFolderCount -gt 0) {
      $queue.Enqueue("$base/mailFolders/$($f.id)/childFolders?`$top=100&`$select=id,displayName,childFolderCount,totalItemCount")
    }
  }
  if ($page.'@odata.nextLink') { $queue.Enqueue($page.'@odata.nextLink') }
}
if (-not $found) {
  Write-Host '  NOT FOUND' -ForegroundColor Red
  Write-Host "  No folder named '$folder' in $mailbox." -ForegroundColor Yellow
  Write-Host '  Set GRAPH_FOLDER in the env file to the exact display name, then re-run.'
  Write-Host ''
  exit 1
}
Write-Host "  OK - $($found.totalItemCount) message(s)" -ForegroundColor Green

$recent = Invoke-RestMethod -Headers $hdr -Uri "$base/mailFolders/$($found.id)/messages?`$top=5&`$orderby=receivedDateTime desc&`$select=subject,receivedDateTime"
Write-Host ''
Write-Host '   Most recent in the folder:'
foreach ($m in $recent.value) {
  $s = [string]$m.subject
  if ($s.Length -gt 60) { $s = $s.Substring(0, 60) + '...' }
  Write-Host ("     {0:yyyy-MM-dd}  {1}" -f [datetime]$m.receivedDateTime, $s)
}

Write-Host ''
Write-Host 'All four checks passed. The bridge is ready to ingest.' -ForegroundColor Green
Write-Host ''
