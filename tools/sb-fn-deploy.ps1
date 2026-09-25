<#
  sb-fn-deploy.ps1 - deploy an Edge Function through the Management API (no Supabase CLI, no Node).

    tools\sb-fn-deploy.ps1 -Name bt-ingest
    tools\sb-fn-deploy.ps1 -Name bt-ingest -NoVerifyJwt     # only if the function must be callable without a JWT

  Deploys supabase\functions\<Name>\index.js as the entrypoint (plain JS on Deno).
#>
param([Parameter(Mandatory)][string]$Name, [switch]$NoVerifyJwt, [string]$ProjectRef = 'bppirsahciuxrqzitfxa')
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$root = Split-Path -Parent $PSScriptRoot
$dir  = Join-Path $root "supabase\functions\$Name"
$entry = Join-Path $dir 'index.js'
if (-not (Test-Path $entry)) { throw "Missing $entry" }
$pat = (Get-Content (Join-Path $env:USERPROFILE '.vbh\supabase_pat.txt') -Raw).Trim()

$meta = @{ name = $Name; entrypoint_path = 'index.js'; verify_jwt = (-not $NoVerifyJwt) } | ConvertTo-Json -Compress

$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $pat)
$form = New-Object System.Net.Http.MultipartFormDataContent
$metaPart = New-Object System.Net.Http.StringContent($meta, [Text.Encoding]::UTF8, 'application/json')
$form.Add($metaPart, 'metadata')
$bytes = [IO.File]::ReadAllBytes($entry)
$filePart = New-Object System.Net.Http.ByteArrayContent(,$bytes)
$filePart.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/javascript')
$form.Add($filePart, 'file', 'index.js')

$uri = "https://api.supabase.com/v1/projects/$ProjectRef/functions/deploy?slug=$Name"
$resp = $client.PostAsync($uri, $form).Result
$text = $resp.Content.ReadAsStringAsync().Result
if (-not $resp.IsSuccessStatusCode) { throw "Deploy failed: $([int]$resp.StatusCode) $text" }
$j = $text | ConvertFrom-Json
"Deployed $Name - version $($j.version) - status $($j.status) - verify_jwt=$($j.verify_jwt)"
"URL: https://$ProjectRef.supabase.co/functions/v1/$Name"
