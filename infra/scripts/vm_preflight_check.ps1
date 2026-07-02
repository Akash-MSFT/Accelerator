<#
    VM Preflight Check - Conversation Knowledge Mining data load
    Run on the Bastion/AVD VM. Uses only built-in PowerShell (no Az CLI / Python needed).
    Purpose: verify DNS resolution + TCP 443 reachability for the private endpoints
    (must resolve to 10.22.144.x private IPs) and the public endpoints (need firewall
    outbound 443). Safe, read-only. Nothing is changed.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Test-Endpoint {
    param(
        [string]$Category,
        [string]$Name,
        [string]$Fqdn,
        [int]$Port = 443,
        [string]$Expect   # 'private' | 'public' | ''
    )

    $dns = Resolve-DnsName -Name $Fqdn -Type A -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress } | Select-Object -First 1
    $ip  = if ($dns) { $dns.IPAddress } else { $null }

    $dnsOk = [bool]$ip
    $isPrivate = $ip -like '10.22.144.*'

    # TCP connectivity (fast timeout)
    $tcpOk = $false
    if ($ip) {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ip, $Port, $null, $null)
        $tcpOk = $iar.AsyncWaitHandle.WaitOne(4000, $false) -and $client.Connected
        $client.Close()
    }

    # Verdict
    $verdict = 'OK'
    if (-not $dnsOk)            { $verdict = 'DNS-FAIL' }
    elseif ($Expect -eq 'private' -and -not $isPrivate) { $verdict = 'WRONG-IP(public?)' }
    elseif (-not $tcpOk)        { $verdict = 'TCP-BLOCKED' }

    [PSCustomObject]@{
        Category = $Category
        Name     = $Name
        FQDN     = $Fqdn
        IP       = if ($ip) { $ip } else { '-' }
        DNS      = if ($dnsOk) { 'yes' } else { 'NO' }
        'TCP443' = if ($tcpOk) { 'yes' } else { 'NO' }
        Verdict  = $verdict
    }
}

$results = @()

Write-Host "`n===== PRIVATE ENDPOINTS (must resolve to 10.22.144.x, in-VNet) =====" -ForegroundColor Cyan
$results += Test-Endpoint 'Private' 'Storage Blob'  'stfoundryrpsidweu01.blob.core.windows.net'  443 'private'
$results += Test-Endpoint 'Private' 'Storage DFS'   'stfoundryrpsidweu01.dfs.core.windows.net'   443 'private'
$results += Test-Endpoint 'Private' 'AI Search'     'srch-foundry-rpsi-dev-weu-01.search.windows.net' 443 'private'
$results += Test-Endpoint 'Private' 'SQL Database'  'sql-cm02dbsd0005.database.windows.net'      1433 'private'
$results += Test-Endpoint 'Private' 'Cosmos DB'     'cosmos-foundry-rpsi-dev-weu-01.documents.azure.com' 443 'private'

Write-Host "`n===== AZURE CONTROL PLANE / AUTH (need outbound 443) =====" -ForegroundColor Cyan
$results += Test-Endpoint 'Azure' 'ARM'        'management.azure.com'        443 'public'
$results += Test-Endpoint 'Azure' 'Entra Login' 'login.microsoftonline.com'  443 'public'
$results += Test-Endpoint 'Azure' 'Graph'      'graph.microsoft.com'         443 'public'

Write-Host "`n===== FOUNDRY / OPENAI DATA PLANE (need outbound 443) =====" -ForegroundColor Cyan
$results += Test-Endpoint 'Foundry' 'Foundry/CU' 'aif-foundry-rpsi-dev-weu-01.services.ai.azure.com' 443 'public'
$results += Test-Endpoint 'Foundry' 'OpenAI'     'aif-foundry-rpsi-dev-weu-01.openai.azure.com'      443 'public'

Write-Host "`n===== TOOLING DOWNLOAD SOURCES (need outbound 443) =====" -ForegroundColor Cyan
$results += Test-Endpoint 'Tooling' 'MS Download' 'download.microsoft.com'      443 'public'
$results += Test-Endpoint 'Tooling' 'aka.ms'      'aka.ms'                      443 'public'
$results += Test-Endpoint 'Tooling' 'Python.org'  'www.python.org'              443 'public'
$results += Test-Endpoint 'Tooling' 'GitHub'      'github.com'                  443 'public'
$results += Test-Endpoint 'Tooling' 'PyPI'        'pypi.org'                    443 'public'
$results += Test-Endpoint 'Tooling' 'PyPI files'  'files.pythonhosted.org'      443 'public'
$results += Test-Endpoint 'Tooling' 'tiktoken'    'openaipublic.blob.core.windows.net' 443 'public'
$results += Test-Endpoint 'Tooling' 'VS Code'     'code.visualstudio.com'       443 'public'

$results | Format-Table -AutoSize

# Summary
$fail = $results | Where-Object { $_.Verdict -ne 'OK' }
Write-Host ""
if ($fail) {
    Write-Host "RESULT: $($fail.Count) issue(s) found -" -ForegroundColor Yellow
    $fail | ForEach-Object { Write-Host ("  [{0}] {1} -> {2}" -f $_.Verdict, $_.Name, $_.FQDN) -ForegroundColor Yellow }
    Write-Host "`nPrivate 'DNS-FAIL' or 'WRONG-IP' => central DNS not resolving private endpoint (needs DNS record or hosts entry)." -ForegroundColor Gray
    Write-Host "Public 'TCP-BLOCKED' => firewall outbound 443 not yet open for that host." -ForegroundColor Gray
} else {
    Write-Host "RESULT: All checks passed - VM can reach private endpoints AND public endpoints." -ForegroundColor Green
}
