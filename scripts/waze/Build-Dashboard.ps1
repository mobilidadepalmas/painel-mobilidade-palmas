<#
Gera o painel HTML (dashboard.html) a partir dos CSVs coletados pelo Get-WazeFeed.ps1.
Autocontido (sem dependencias externas) para poder ser aberto localmente offline.
#>

param(
    [string]$OutDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$processedDir = Join-Path $OutDir "processed"

function Import-CsvSafe($path) {
    if (Test-Path $path) { return @(Import-Csv $path) }
    return @()
}

function Get-NumOrNull($val) {
    if ([string]::IsNullOrWhiteSpace($val)) { return $null }
    $n = 0.0
    if ([double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $n }
    return $null
}

$alerts = Import-CsvSafe (Join-Path $processedDir "alerts.csv")
$jams   = Import-CsvSafe (Join-Path $processedDir "jams.csv")
$tv     = Import-CsvSafe (Join-Path $processedDir "traffic_view.csv")

$latestAlertsTs = ($alerts | Select-Object -ExpandProperty collected_at -Unique | Sort-Object -Descending | Select-Object -First 1)
$latestJamsTs   = ($jams   | Select-Object -ExpandProperty collected_at -Unique | Sort-Object -Descending | Select-Object -First 1)

$latestAlerts = @($alerts | Where-Object { $_.collected_at -eq $latestAlertsTs })
$latestJams   = @($jams   | Where-Object { $_.collected_at -eq $latestJamsTs })

# ---- alerts by type (snapshot atual) ----
$alertsByType = @($latestAlerts | Group-Object type | Sort-Object Count -Descending | ForEach-Object {
    [ordered]@{ label = $_.Name; value = $_.Count }
})

# ---- vias com mais ocorrencias de congestionamento (historico completo) ----
$topStreetsGroups = @($jams | Where-Object { $_.street -and $_.street.Trim() -ne "" } |
    Group-Object street | Sort-Object Count -Descending | Select-Object -First 10)

$topStreets = @($topStreetsGroups | ForEach-Object {
    [ordered]@{ label = $_.Name; value = $_.Count }
})

# detalhe de ocorrencias por via (pra mostrar quando o usuario clica na barra)
$topStreetsDetail = [ordered]@{}
foreach ($g in $topStreetsGroups) {
    $ocorrencias = $g.Group | Sort-Object collected_at -Descending | Select-Object -First 30 | ForEach-Object {
        [ordered]@{
            collected_at = $_.collected_at
            level        = $_.level
            speedKMH     = Get-NumOrNull $_.speedKMH
            lat          = Get-NumOrNull $_.lat
            lon          = Get-NumOrNull $_.lon
        }
    }
    $topStreetsDetail[$g.Name] = $ocorrencias
}

# ---- severidade dos congestionamentos ativos agora ----
$sevGood = 0; $sevWarning = 0; $sevSerious = 0; $sevCritical = 0
foreach ($j in $latestJams) {
    $lvl = 0
    [int]::TryParse($j.level, [ref]$lvl) | Out-Null
    if     ($lvl -le 1) { $sevGood++ }
    elseif ($lvl -eq 2) { $sevWarning++ }
    elseif ($lvl -le 4) { $sevSerious++ }
    else                { $sevCritical++ }
}
$severityLabel = "good"
if ($sevCritical -gt 0)      { $severityLabel = "critical" }
elseif ($sevSerious -gt 0)   { $severityLabel = "serious" }
elseif ($sevWarning -gt 0)   { $severityLabel = "warning" }

# ---- serie temporal (Traffic View) ----
$tvSorted = @($tv | Sort-Object collected_at)
$timestamps = @($tvSorted | ForEach-Object { $_.collected_at })

function Get-NumOrZero($val) {
    if ([string]::IsNullOrWhiteSpace($val)) { return 0 }
    $n = 0.0
    [double]::TryParse($val, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n) | Out-Null
    return $n
}

$usersByLevel  = [ordered]@{}
foreach ($l in 0..4) {
    $usersByLevel["$l"] = @($tvSorted | ForEach-Object { Get-NumOrZero $_."usersOnJams_level$l" })
}
$lengthByLevel = [ordered]@{}
foreach ($l in 1..5) {
    $lengthByLevel["$l"] = @($tvSorted | ForEach-Object { Get-NumOrZero $_."lengthOfJams_level$l" })
}

$usersInJamsNow = 0.0
if ($tvSorted.Count -gt 0) {
    $lastTv = $tvSorted[-1]
    foreach ($l in 1..4) { $usersInJamsNow += (Get-NumOrZero $lastTv."usersOnJams_level$l") }
}

# ---- pontos criticos: clusters de congestionamento recorrente com coordenadas ----
$jamsWithCoords = @($jams | Where-Object { (Get-NumOrNull $_.lat) -ne $null -and (Get-NumOrNull $_.lon) -ne $null })
$clusterKeyed = $jamsWithCoords | ForEach-Object {
    $latR = [math]::Round((Get-NumOrNull $_.lat), 4)
    $lonR = [math]::Round((Get-NumOrNull $_.lon), 4)
    $_ | Add-Member -NotePropertyName clusterKey -NotePropertyValue ("$latR|$lonR|$($_.street)") -PassThru -Force
}
$criticalPoints = @($clusterKeyed | Group-Object clusterKey | Sort-Object Count -Descending | Select-Object -First 20 | ForEach-Object {
    $rows = $_.Group
    $lvls = $rows | ForEach-Object { $l = 0; [int]::TryParse($_.level, [ref]$l) | Out-Null; $l }
    $avgLevel = ($lvls | Measure-Object -Average).Average
    $maxLevel = ($lvls | Measure-Object -Maximum).Maximum
    $sevKey = "good"
    if     ($maxLevel -ge 5) { $sevKey = "critical" }
    elseif ($maxLevel -ge 3) { $sevKey = "serious" }
    elseif ($maxLevel -ge 2) { $sevKey = "warning" }
    $lastRow = $rows | Sort-Object collected_at -Descending | Select-Object -First 1
    [ordered]@{
        lat            = [math]::Round((($rows | ForEach-Object { Get-NumOrNull $_.lat } | Measure-Object -Average).Average), 6)
        lon            = [math]::Round((($rows | ForEach-Object { Get-NumOrNull $_.lon } | Measure-Object -Average).Average), 6)
        street         = $lastRow.street
        occurrences    = $rows.Count
        avgLevel       = [math]::Round($avgLevel, 1)
        maxLevel       = $maxLevel
        severityLabel  = $sevKey
        lastSeen       = $lastRow.collected_at
        avgSpeedKMH    = [math]::Round((($rows | ForEach-Object { Get-NumOrNull $_.speedKMH } | Measure-Object -Average).Average), 1)
    }
})

# ---- alertas ativos agora com coordenadas (para o mapa) ----
$hazardPoints = @($latestAlerts | Where-Object { (Get-NumOrNull $_.lat) -ne $null -and (Get-NumOrNull $_.lon) -ne $null } | ForEach-Object {
    [ordered]@{
        uuid        = $_.uuid
        lat         = Get-NumOrNull $_.lat
        lon         = Get-NumOrNull $_.lon
        type        = $_.type
        subtype     = $_.subtype
        street      = $_.street
        city        = $_.city
        reliability = $_.reliability
        confidence  = $_.confidence
        pubDateUtc  = $_.pubDateUtc
        pubMillis   = $_.pubMillis
    }
})

# ---- registro mais recente (para o aviso de "Atualizacao" ao abrir a pagina) ----
$latestReport = $null
$alertComPubMillis = @($alerts | Where-Object { $_.pubMillis -and $_.pubMillis.Trim() -ne "" })
if ($alertComPubMillis.Count -gt 0) {
    $maisRecente = $alertComPubMillis | Sort-Object { [int64]$_.pubMillis } -Descending | Select-Object -First 1
    $latestReport = [ordered]@{
        uuid       = $maisRecente.uuid
        type       = $maisRecente.type
        subtype    = $maisRecente.subtype
        street     = $maisRecente.street
        lat        = Get-NumOrNull $maisRecente.lat
        lon        = Get-NumOrNull $maisRecente.lon
        pubDateUtc = $maisRecente.pubDateUtc
    }
}

# ---- acidentes recentes (ultimas 5h) para o indicador piscante "ACIDENTE" no titulo ----
$nowUtc = (Get-Date).ToUniversalTime()
$janelaAcidentes = $nowUtc.AddHours(-5)
$recentAccidents = @($alerts | Where-Object {
    $_.type -eq "ACCIDENT" -and $_.pubDateUtc -and $_.pubDateUtc.Trim() -ne "" -and
    ([datetime]$_.pubDateUtc) -ge $janelaAcidentes
} | Select-Object -ExpandProperty uuid -Unique)
$recentAccidentsCount = $recentAccidents.Count

# ---- dados brutos (linha a linha) para o filtro de periodo no navegador ----
# limitado as ultimas 5000 linhas de cada pra o arquivo nao crescer demais com o tempo
$rawAlerts = @($alerts | Where-Object { (Get-NumOrNull $_.lat) -ne $null -and (Get-NumOrNull $_.lon) -ne $null } |
    Select-Object -Last 5000 | ForEach-Object {
        [ordered]@{
            t = $_.collected_at; uuid = $_.uuid; type = $_.type; subtype = $_.subtype; street = $_.street
            lat = Get-NumOrNull $_.lat; lon = Get-NumOrNull $_.lon
            confidence = Get-NumOrNull $_.confidence; reliability = Get-NumOrNull $_.reliability
            pubDateUtc = $_.pubDateUtc
        }
    })

$rawJams = @($jams | Select-Object -Last 5000 | ForEach-Object {
    [ordered]@{
        t = $_.collected_at; id = $_.id; street = $_.street; level = (Get-NumOrNull $_.level)
        speedKMH = Get-NumOrNull $_.speedKMH; length_m = Get-NumOrNull $_.length_m
        lat = Get-NumOrNull $_.lat; lon = Get-NumOrNull $_.lon
    }
})

$tvTableRows = @($tvSorted | Select-Object -Last 50 | ForEach-Object {
    [ordered]@{
        t = $_.collected_at
        u0 = Get-NumOrZero $_.usersOnJams_level0; u1 = Get-NumOrZero $_.usersOnJams_level1
        u2 = Get-NumOrZero $_.usersOnJams_level2; u3 = Get-NumOrZero $_.usersOnJams_level3
        u4 = Get-NumOrZero $_.usersOnJams_level4
        l1 = Get-NumOrZero $_.lengthOfJams_level1; l2 = Get-NumOrZero $_.lengthOfJams_level2
        l3 = Get-NumOrZero $_.lengthOfJams_level3; l4 = Get-NumOrZero $_.lengthOfJams_level4
        l5 = Get-NumOrZero $_.lengthOfJams_level5
    }
})

$data = [ordered]@{
    generatedAt    = (Get-Date).ToString("s")
    lastCollection = $latestJamsTs
    totals = [ordered]@{
        activeAlerts   = $latestAlerts.Count
        activeJams     = $latestJams.Count
        usersInJamsNow = [math]::Round($usersInJamsNow)
        severityLabel  = $severityLabel
        collections    = $tvSorted.Count
    }
    alertsByType = $alertsByType
    topStreets   = $topStreets
    severity     = [ordered]@{ good = $sevGood; warning = $sevWarning; serious = $sevSerious; critical = $sevCritical }
    criticalPoints = $criticalPoints
    hazardPoints   = $hazardPoints
    latestReport   = $latestReport
    recentAccidentsCount = $recentAccidentsCount
    topStreetsDetail = $topStreetsDetail
    rawAlerts      = $rawAlerts
    rawJams        = $rawJams
    timeSeries   = [ordered]@{
        timestamps    = $timestamps
        usersByLevel  = $usersByLevel
        lengthByLevel = $lengthByLevel
    }
    tvTable = $tvTableRows
}

$json = $data | ConvertTo-Json -Depth 10 -Compress

$template = Get-Content -Path (Join-Path $PSScriptRoot "dashboard_template.html") -Raw -Encoding UTF8
$html = $template.Replace("__DATA_JSON__", $json)

$outPath = Join-Path $OutDir "dashboard.html"
$html | Out-File -FilePath $outPath -Encoding utf8 -NoNewline
Write-Host "Painel gerado em: $outPath"
