<#
  bt-set-graph-creds.ps1 - enter the Microsoft Graph values from IT.

  Prompts only for values not already present in %USERPROFILE%\.vbh\bt-graph.env
  (outside the repo), then pushes them to Supabase as Edge Function secrets.
  The client secret is typed masked and is never echoed, logged, or committed.

    powershell -ExecutionPolicy Bypass -File tools\bt-set-graph-creds.ps1
    powershell -ExecutionPolicy Bypass -File tools\bt-set-graph-creds.ps1 -All   # re-enter everything
#>
param([switch]$All)
$ErrorActionPreference = 'Stop'
$envFile = Join-Path $env:USERPROFILE '.vbh\bt-graph.env'
if (-not (Test-Path $envFile)) { throw "Missing $envFile" }

# What is already set (uncommented lines only)?
$have = @{}
foreach ($line in Get-Content $envFile) {
  if ($line -match '^\s*([A-Z_]+)\s*=\s*(.+)$') { $have[$Matches[1]] = $Matches[2].Trim() }
}

$guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
Write-Host ""
Write-Host "Microsoft Graph credentials" -ForegroundColor Cyan

$tenant = $have['GRAPH_TENANT_ID']; $client = $have['GRAPH_CLIENT_ID']
if ($All -or -not $tenant) {
  $tenant = (Read-Host 'Tenant ID (Directory (tenant) ID)').Trim()
  if ($tenant -notmatch $guid) { throw "Tenant ID doesn't look like a GUID (got $($tenant.Length) chars)." }
} else { Write-Host "  Tenant ID ......... already set" -ForegroundColor DarkGray }

if ($All -or -not $client) {
  $client = (Read-Host 'Application (client) ID').Trim()
  if ($client -notmatch $guid) { throw "Client ID doesn't look like a GUID (got $($client.Length) chars)." }
} else { Write-Host "  Client ID ......... already set" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "Paste the client secret VALUE (~40 chars, not the Secret ID)." -ForegroundColor Yellow
Write-Host "Nothing will appear as you type - that is expected. Press Enter when done."
$secure = Read-Host '  Client secret VALUE' -AsSecureString
$secret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()

if ($secret -match $guid)  { throw "That is the Secret ID (a GUID), not the Value. Azure shows the Value only once - IT must issue a new secret and send the Value column." }
if ($secret.Length -lt 20) { throw "Too short to be a secret Value ($($secret.Length) chars). Ask IT for the Value column." }

$lines = Get-Content $envFile | Where-Object { $_ -notmatch '^\s*#?\s*GRAPH_(TENANT_ID|CLIENT_ID|CLIENT_SECRET)\s*=' }
$lines += "GRAPH_TENANT_ID=$tenant"
$lines += "GRAPH_CLIENT_ID=$client"
$lines += "GRAPH_CLIENT_SECRET=$secret"
Set-Content -Path $envFile -Value $lines -Encoding UTF8

Write-Host ""
Write-Host "Saved ($($secret.Length)-character secret) to $envFile" -ForegroundColor Green
& (Join-Path $PSScriptRoot 'sb-fn-secrets.ps1')
Write-Host ""
Write-Host "Done. Tell Claude the credentials are in." -ForegroundColor Green
