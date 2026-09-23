<#
  bt-set-graph-creds.ps1 · enter the three Microsoft Graph values from IT.

  Prompts for each value, writes them to %USERPROFILE%\.vbh\bt-graph.env (outside
  the repo), and pushes them to Supabase as Edge Function secrets. The client
  secret is typed masked and is never echoed, logged, or committed.

    powershell -ExecutionPolicy Bypass -File tools\bt-set-graph-creds.ps1
#>
$ErrorActionPreference = 'Stop'
$envFile = Join-Path $env:USERPROFILE '.vbh\bt-graph.env'
if (-not (Test-Path $envFile)) { throw "Missing $envFile" }

Write-Host ""
Write-Host "Microsoft Graph credentials from IT" -ForegroundColor Cyan
Write-Host "Paste each value and press Enter. The secret will not be shown as you type."
Write-Host ""

$tenant = (Read-Host 'Tenant ID (Directory (tenant) ID)').Trim()
$client = (Read-Host 'Application (client) ID').Trim()
$secure = Read-Host 'Client secret VALUE' -AsSecureString
$secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()

$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
if ($tenant -notmatch $guid) { throw "Tenant ID doesn't look like a GUID. Got $($tenant.Length) chars." }
if ($client -notmatch $guid) { throw "Client ID doesn't look like a GUID. Got $($client.Length) chars." }
if ($secret.Length -lt 20)   { throw "That looks like a Secret ID, not the secret VALUE (only $($secret.Length) chars). Ask IT for the Value column." }
if ($secret -match $guid)    { throw "That's the Secret ID (a GUID), not the secret VALUE. Ask IT for the Value column - it's only shown once, so they may need to issue a new secret." }

$lines = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#?\s*GRAPH_(TENANT_ID|CLIENT_ID|CLIENT_SECRET)\s*=' }
$lines += "GRAPH_TENANT_ID=$tenant"
$lines += "GRAPH_CLIENT_ID=$client"
$lines += "GRAPH_CLIENT_SECRET=$secret"
Set-Content -Path $envFile -Value $lines -Encoding UTF8

Write-Host ""
Write-Host "Saved to $envFile" -ForegroundColor Green
& (Join-Path $PSScriptRoot 'sb-fn-secrets.ps1')
Write-Host ""
Write-Host "Done. Tell Claude the credentials are in - it will run the backfill." -ForegroundColor Green
