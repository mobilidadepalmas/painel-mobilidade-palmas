<#
Coleta o Waze Data Feed (Partner Hub) e acumula os dados em CSV para análise histórica.
Feed atualiza a cada ~2 minutos no lado do Waze; rode este script nesse intervalo (ou menos frequente).

SEGURANÇA: a URL do feed é uma credencial (funciona como token de acesso do Partner Hub da
SEMOB) — por isso NÃO fica hardcoded aqui. No GitHub Actions, vem dos secrets WAZE_FEED_URL e
WAZE_TRAFFICVIEW_URL (ver .github/workflows/update-waze.yml). Ao rodar localmente, passe via
parâmetro ou variável de ambiente.
#>

param(
    [string]$FeedUrl = $env:WAZE_FEED_URL,
    [string]$TrafficViewUrl = $env:WAZE_TRAFFICVIEW_URL,
    [string]$OutDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($FeedUrl)) {
    Write-Error "FeedUrl não informado. Passe -FeedUrl ou defina a variável de ambiente WAZE_FEED_URL."
    exit 1
}
# forca ponto decimal (evita "10,29" em vez de "10.29" gravado por localidades pt-BR)
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

$rawDir       = Join-Path $OutDir "raw"
$processedDir = Join-Path $OutDir "processed"
New-Item -ItemType Directory -Force -Path $rawDir       | Out-Null
New-Item -ItemType Directory -Force -Path $processedDir | Out-Null

$collectedAt = (Get-Date).ToUniversalTime()
# collected_at em UTC (igual pubDateUtc) para o dashboard converter certo pro fuso do navegador
$stamp       = $collectedAt.ToString("yyyyMMdd_HHmmss")

try {
    $response = Invoke-RestMethod -Uri $FeedUrl -Method Get -TimeoutSec 30
}
catch {
    $logLine = "$($collectedAt.ToString('s')),ERROR,$($_.Exception.Message)"
    Add-Content -Path (Join-Path $processedDir "collection_log.csv") -Value $logLine
    Write-Error "Falha ao buscar o feed: $($_.Exception.Message)"
    exit 1
}

# snapshot bruto (JSON) para auditoria/reprocessamento futuro
$rawPath = Join-Path $rawDir "waze_feed_$stamp.json"
$response | ConvertTo-Json -Depth 10 | Out-File -FilePath $rawPath -Encoding utf8

# ---------- Alerts ----------
$alertsCsv = Join-Path $processedDir "alerts.csv"
$alertRows = foreach ($a in $response.alerts) {
    [PSCustomObject]@{
        collected_at         = $collectedAt.ToString("s")
        uuid                 = $a.uuid
        type                 = $a.type
        subtype              = $a.subtype
        pubMillis            = $a.pubMillis
        pubDateUtc           = if ($a.pubMillis) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$a.pubMillis).UtcDateTime.ToString("s") } else { "" }
        street               = $a.street
        city                 = $a.city
        country              = $a.country
        roadType             = $a.roadType
        lat                  = $a.location.y
        lon                  = $a.location.x
        confidence           = $a.confidence
        reliability          = $a.reliability
        reportRating         = $a.reportRating
        nThumbsUp            = $a.nThumbsUp
        reportByMunicipality = $a.reportByMunicipalityUser
    }
}
$alertExists = Test-Path $alertsCsv
$alertRows | Export-Csv -Path $alertsCsv -NoTypeInformation -Append:$alertExists -Encoding utf8

# ---------- Jams ----------
$jamsCsv = Join-Path $processedDir "jams.csv"
$jamRows = foreach ($j in $response.jams) {
    $lineLat = $null; $lineLon = $null
    if ($j.line -and $j.line.Count -gt 0) {
        $lineLat = [math]::Round((($j.line | ForEach-Object { [double]$_.y } | Measure-Object -Average).Average), 6)
        $lineLon = [math]::Round((($j.line | ForEach-Object { [double]$_.x } | Measure-Object -Average).Average), 6)
    }
    [PSCustomObject]@{
        collected_at      = $collectedAt.ToString("s")
        id                = $j.id
        street             = $j.street
        endNode            = $j.endNode
        city               = $j.city
        country            = $j.country
        roadType           = $j.roadType
        speedKMH           = $j.speedKMH
        level              = $j.level
        length_m           = $j.length
        delay_s            = $j.delay
        lat                = $lineLat
        lon                = $lineLon
        pubMillis          = $j.pubMillis
        pubDateUtc         = if ($j.pubMillis) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$j.pubMillis).UtcDateTime.ToString("s") } else { "" }
        blockingAlertUuid  = $j.blockingAlertUuid
    }
}
$jamExists = Test-Path $jamsCsv
$jamRows | Export-Csv -Path $jamsCsv -NoTypeInformation -Append:$jamExists -Encoding utf8

# ---------- Traffic View (estatísticas agregadas em tempo real) ----------
if (-not [string]::IsNullOrWhiteSpace($TrafficViewUrl)) {
try {
    $tv = Invoke-RestMethod -Uri $TrafficViewUrl -Method Get -TimeoutSec 30

    $tvRawPath = Join-Path $rawDir "traffic_view_$stamp.json"
    $tv | ConvertTo-Json -Depth 10 | Out-File -FilePath $tvRawPath -Encoding utf8

    $tvRow = [ordered]@{
        collected_at = $collectedAt.ToString("s")
        areaName     = $tv.areaName
        updateTime   = $tv.updateTime
        updateTimeUtc = if ($tv.updateTime) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$tv.updateTime).UtcDateTime.ToString("s") } else { "" }
    }
    foreach ($u in $tv.usersOnJams) { $tvRow["usersOnJams_level$($u.jamLevel)"] = $u.wazersCount }
    foreach ($l in $tv.lengthOfJams) { $tvRow["lengthOfJams_level$($l.jamLevel)"] = $l.jamLength }
    $tvRow["routesCount"] = $tv.routes.Count
    $tvRow["irregularitiesCount"] = $tv.irregularities.Count

    $tvCsv = Join-Path $processedDir "traffic_view.csv"
    $tvExists = Test-Path $tvCsv
    [PSCustomObject]$tvRow | Export-Csv -Path $tvCsv -NoTypeInformation -Append:$tvExists -Encoding utf8

    # ---------- Irregularities (anomalias de trafego detectadas pelo Waze vs tempo historico da rota) ----------
    $irregRows = foreach ($ir in $tv.irregularities) {
        $irLat = $null; $irLon = $null
        if ($ir.line -and $ir.line.Count -gt 0) {
            $irLat = [math]::Round((($ir.line | ForEach-Object { [double]$_.y } | Measure-Object -Average).Average), 6)
            $irLon = [math]::Round((($ir.line | ForEach-Object { [double]$_.x } | Measure-Object -Average).Average), 6)
        }
        [PSCustomObject]@{
            collected_at = $collectedAt.ToString("s")
            id           = $ir.id
            name         = $ir.name
            fromName     = $ir.fromName
            toName       = $ir.toName
            jamLevel     = $ir.jamLevel
            length_m     = $ir.length
            time_s       = $ir.time
            historicTime_s = $ir.historicTime
            delay_s      = if ($ir.time -and $ir.historicTime) { [int]$ir.time - [int]$ir.historicTime } else { $null }
            type         = $ir.type
            lat          = $irLat
            lon          = $irLon
        }
    }
    if ($irregRows) {
        $irregCsv = Join-Path $processedDir "irregularities.csv"
        $irregExists = Test-Path $irregCsv
        $irregRows | Export-Csv -Path $irregCsv -NoTypeInformation -Append:$irregExists -Encoding utf8
    }
}
catch {
    Add-Content -Path (Join-Path $processedDir "collection_log.csv") -Value "$($collectedAt.ToString('s')),ERROR_TRAFFICVIEW,$($_.Exception.Message)"
}
}

# log de execução + limpeza de snapshots brutos com mais de 7 dias
$logLine = "$($collectedAt.ToString('s')),OK,alerts=$($alertRows.Count);jams=$($jamRows.Count)"
Add-Content -Path (Join-Path $processedDir "collection_log.csv") -Value $logLine

Get-ChildItem $rawDir -Include "waze_feed_*.json","traffic_view_*.json" -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force

Write-Host "OK: $($alertRows.Count) alerts, $($jamRows.Count) jams coletados em $stamp"
