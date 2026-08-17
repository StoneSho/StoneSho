param(
    [string]$Username = "StoneSho"
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $projectRoot "assets"
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$to = (Get-Date).ToUniversalTime()
$from = $to.AddDays(-364)
$fromIso = $from.ToString("yyyy-MM-ddTHH:mm:ssZ")
$toIso = $to.ToString("yyyy-MM-ddTHH:mm:ssZ")

$query = @"
query {
  user(login: "$Username") {
    contributions: contributionsCollection(from: "$fromIso", to: "$toIso") {
      contributionCalendar {
        totalContributions
        weeks {
          contributionDays {
            date
            contributionCount
          }
        }
      }
    }
    repositories(first: 100, ownerAffiliations: OWNER, privacy: PUBLIC, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        isFork
        languages(first: 8, orderBy: {field: SIZE, direction: DESC}) {
          edges {
            size
            node {
              name
              color
            }
          }
        }
      }
    }
  }
}
"@

$rawResponse = & gh api graphql -f "query=$query"
if ($LASTEXITCODE -ne 0) {
    throw "GitHub GraphQL query failed. Run 'gh auth login' and try again."
}

$response = $rawResponse | ConvertFrom-Json
if ($response.errors -or -not $response.data.user) {
    throw "GitHub did not return usable profile data."
}

$user = $response.data.user
$calendar = $user.contributions.contributionCalendar
$days = [System.Collections.Generic.List[object]]::new()
foreach ($week in $calendar.weeks) {
    foreach ($day in $week.contributionDays) {
        [void]$days.Add($day)
    }
}

function Format-Number([Int64]$Value) {
    return $Value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-SignalColor([Int64]$Count, [Int64]$Maximum) {
    if ($Count -le 0) { return "#3a3f4b" }

    $ratio = $Count / [Math]::Max(1, $Maximum)
    if ($ratio -le 0.25) { return "#69d2e7" }
    if ($ratio -le 0.50) { return "#45c4b0" }
    if ($ratio -le 0.75) { return "#ffd166" }
    return "#ff8a65"
}

function Write-Svg([string]$FileName, [System.Collections.Generic.List[string]]$Lines) {
    $path = Join-Path $outputDirectory $FileName
    [System.IO.File]::WriteAllText($path, ($Lines -join "`n"), [System.Text.UTF8Encoding]::new($false))
}

$totalContributions = [Int64]$calendar.totalContributions
$activeDays = @($days | Where-Object { [Int64]$_.contributionCount -gt 0 }).Count
$longestStreak = 0
$streak = 0
foreach ($day in $days) {
    if ([Int64]$day.contributionCount -gt 0) {
        $streak++
        $longestStreak = [Math]::Max($longestStreak, $streak)
    }
    else {
        $streak = 0
    }
}

$monthTotals = @{}
foreach ($day in $days) {
    $monthKey = ([DateTime]::Parse($day.date)).ToString("yyyy-MM")
    if (-not $monthTotals.ContainsKey($monthKey)) {
        $monthTotals[$monthKey] = [Int64]0
    }
    $monthTotals[$monthKey] += [Int64]$day.contributionCount
}

$monthKeys = @($monthTotals.Keys | Sort-Object)
$monthData = foreach ($monthKey in $monthKeys) {
    [PSCustomObject]@{
        Key = $monthKey
        Label = ([DateTime]::ParseExact($monthKey, "yyyy-MM", $null)).ToString("MMM", [System.Globalization.CultureInfo]::InvariantCulture)
        Count = [Int64]$monthTotals[$monthKey]
    }
}

$maximumMonth = [Int64](($monthData | Measure-Object -Property Count -Maximum).Maximum)
$mostActiveMonth = @($monthData | Sort-Object Count -Descending | Select-Object -First 1)[0]

$weekData = [System.Collections.Generic.List[object]]::new()
foreach ($week in $calendar.weeks) {
    $weekTotal = [Int64]0
    foreach ($day in $week.contributionDays) {
        $weekTotal += [Int64]$day.contributionCount
    }
    [void]$weekData.Add([PSCustomObject]@{
        Start = [DateTime]::Parse($week.contributionDays[0].date)
        End = [DateTime]::Parse($week.contributionDays[$week.contributionDays.Count - 1].date)
        Count = $weekTotal
    })
}

$maximumWeek = [Int64](($weekData | Measure-Object -Property Count -Maximum).Maximum)
$peakWeek = @($weekData | Sort-Object Count -Descending | Select-Object -First 1)[0]
$chartLeft = 58
$chartRight = 1022
$chartBaseline = 286
$chartHeight = 94
$weekSpacing = ($chartRight - $chartLeft) / [Math]::Max(1, ($weekData.Count - 1))
$signalPoints = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $weekData.Count; $index++) {
    $week = $weekData[$index]
    $ratio = $week.Count / [Math]::Max(1, $maximumWeek)
    $amplitude = [Math]::Pow($ratio, 0.62) * $chartHeight
    [void]$signalPoints.Add([PSCustomObject]@{
        X = [Int32][Math]::Round($chartLeft + ($index * $weekSpacing))
        Y = [Int32][Math]::Round($chartBaseline - $amplitude)
        Start = $week.Start
        End = $week.End
        Count = $week.Count
    })
}

$firstPoint = $signalPoints[0]
$lastPoint = $signalPoints[$signalPoints.Count - 1]
$signalPath = "M $($firstPoint.X) $($firstPoint.Y)"
$areaPath = "M $($firstPoint.X) $chartBaseline L $($firstPoint.X) $($firstPoint.Y)"
for ($index = 1; $index -lt $signalPoints.Count; $index++) {
    $previous = $signalPoints[$index - 1]
    $current = $signalPoints[$index]
    $controlX = [Int32][Math]::Round(($previous.X + $current.X) / 2)
    $curve = " C $controlX $($previous.Y), $controlX $($current.Y), $($current.X) $($current.Y)"
    $signalPath += $curve
    $areaPath += $curve
}
$areaPath += " L $($lastPoint.X) $chartBaseline Z"

$monthMarkers = [System.Collections.Generic.List[object]]::new()
$seenMonths = @{}
foreach ($point in $signalPoints) {
    $monthKey = $point.Start.ToString("yyyy-MM")
    if (-not $seenMonths.ContainsKey($monthKey)) {
        $seenMonths[$monthKey] = $true
        [void]$monthMarkers.Add([PSCustomObject]@{
            X = $point.X
            Label = $point.Start.ToString("MMM", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
        })
    }
}

$contributionSvg = [System.Collections.Generic.List[string]]::new()
[void]$contributionSvg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="356" viewBox="0 0 1080 356" role="img" aria-labelledby="title desc">')
[void]$contributionSvg.Add('<title id="title">Annual contribution rhythm</title>')
[void]$contributionSvg.Add('<desc id="desc">A weekly contribution signal route across the last year.</desc>')
[void]$contributionSvg.Add('<rect width="1080" height="356" rx="8" fill="#16171d"/>')
[void]$contributionSvg.Add('<rect x="1" y="1" width="1078" height="354" rx="7" fill="none" stroke="#393c46"/>')
[void]$contributionSvg.Add(('<text x="40" y="45" fill="#f4f1ea" font-family="Arial Black,Arial,sans-serif" font-size="22">{0} // BUILD RHYTHM</text>' -f $Username.ToUpperInvariant()))
[void]$contributionSvg.Add('<text x="40" y="68" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="12">A YEAR OF WEEKLY CONTRIBUTION SIGNALS</text>')
[void]$contributionSvg.Add('<text x="1038" y="44" fill="#69d2e7" font-family="Cascadia Mono,Consolas,monospace" font-size="12" text-anchor="end">365D / ACTIVITY DATA</text>')

$summary = @(
    [PSCustomObject]@{ Label = "TOTAL"; Value = (Format-Number $totalContributions); Color = "#69d2e7" },
    [PSCustomObject]@{ Label = "ACTIVE DAYS"; Value = (Format-Number $activeDays); Color = "#45c4b0" },
    [PSCustomObject]@{ Label = "LONGEST RUN"; Value = ("{0}D" -f $longestStreak); Color = "#ffd166" },
    [PSCustomObject]@{ Label = "PEAK MONTH"; Value = ("{0} / {1}" -f $mostActiveMonth.Label.ToUpperInvariant(), (Format-Number $mostActiveMonth.Count)); Color = "#ff8a65" }
)

for ($index = 0; $index -lt $summary.Count; $index++) {
    $entry = $summary[$index]
    $x = 40 + ($index * 256)
    [void]$contributionSvg.Add(('<text x="{0}" y="102" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="11">{1}</text>' -f $x, $entry.Label))
    [void]$contributionSvg.Add(('<text x="{0}" y="134" fill="{1}" font-family="Cascadia Mono,Consolas,monospace" font-size="25" font-weight="700">{2}</text>' -f $x, $entry.Color, $entry.Value))
    if ($index -lt ($summary.Count - 1)) {
        $lineX = $x + 224
        [void]$contributionSvg.Add(('<line x1="{0}" y1="88" x2="{0}" y2="141" stroke="#393c46"/>' -f $lineX))
    }
}

[void]$contributionSvg.Add('<text x="40" y="171" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="11">WEEKLY SIGNAL ROUTE</text>')
[void]$contributionSvg.Add('<line x1="58" y1="239" x2="1022" y2="239" stroke="#2b2e37" stroke-dasharray="3 9"/>')
[void]$contributionSvg.Add('<line x1="58" y1="286" x2="1022" y2="286" stroke="#454955"/>')
[void]$contributionSvg.Add(('<path d="{0}" fill="#203a43" fill-opacity="0.46"/>' -f $areaPath))
[void]$contributionSvg.Add(('<path d="{0}" fill="none" stroke="#69d2e7" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>' -f $signalPath))

foreach ($point in $signalPoints) {
    $color = Get-SignalColor $point.Count $maximumWeek
    $radius = if ($point.Count -eq 0) { 2 } else { 4 + [Int32][Math]::Round(7 * [Math]::Pow(($point.Count / [Math]::Max(1, $maximumWeek)), 0.65)) }
    [void]$contributionSvg.Add(('<circle cx="{0}" cy="{1}" r="{2}" fill="{3}" stroke="#16171d" stroke-width="2"><title>{4} to {5}: {6} contributions</title></circle>' -f $point.X, $point.Y, $radius, $color, $point.Start.ToString("yyyy-MM-dd"), $point.End.ToString("yyyy-MM-dd"), $point.Count))
}

$peakPoint = @($signalPoints | Where-Object { $_.Start -eq $peakWeek.Start } | Select-Object -First 1)[0]
$peakLabelY = [Int32][Math]::Max(181, ($peakPoint.Y - 23))
[void]$contributionSvg.Add(('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#ff8a65" stroke-width="1"/>' -f $peakPoint.X, ($peakPoint.Y - 7), ($peakLabelY + 5)))
[void]$contributionSvg.Add(('<text x="{0}" y="{1}" fill="#ff8a65" font-family="Cascadia Mono,Consolas,monospace" font-size="11" font-weight="700" text-anchor="middle">PEAK / {2}</text>' -f $peakPoint.X, $peakLabelY, (Format-Number $peakPoint.Count)))

foreach ($marker in $monthMarkers) {
    [void]$contributionSvg.Add(('<line x1="{0}" y1="291" x2="{0}" y2="296" stroke="#5a6170"/>' -f $marker.X))
    [void]$contributionSvg.Add(('<text x="{0}" y="319" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="10" text-anchor="middle">{1}</text>' -f $marker.X, $marker.Label))
}

[void]$contributionSvg.Add('<text x="40" y="343" fill="#727887" font-family="Cascadia Mono,Consolas,monospace" font-size="10">LOW</text>')
for ($index = 0; $index -lt 4; $index++) {
    $legendX = 76 + ($index * 20)
    $legendCount = [Math]::Max(1, [Math]::Ceiling($maximumWeek * ($index + 1) / 4))
    [void]$contributionSvg.Add(('<circle cx="{0}" cy="340" r="5" fill="{1}"/>' -f $legendX, (Get-SignalColor $legendCount $maximumWeek)))
}
[void]$contributionSvg.Add('<text x="161" y="343" fill="#727887" font-family="Cascadia Mono,Consolas,monospace" font-size="10">HIGH</text>')
[void]$contributionSvg.Add('<text x="1038" y="343" fill="#727887" font-family="Cascadia Mono,Consolas,monospace" font-size="10" text-anchor="end">WEEKLY TOTALS / NO SYNTHETIC ACTIVITY</text>')
[void]$contributionSvg.Add('</svg>')
Write-Svg "contributions.svg" $contributionSvg

$mobileLeft = 32
$mobileRight = 508
$mobileBaseline = 402
$mobileChartHeight = 102
$mobileSpacing = ($mobileRight - $mobileLeft) / [Math]::Max(1, ($weekData.Count - 1))
$mobilePoints = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $weekData.Count; $index++) {
    $week = $weekData[$index]
    $ratio = $week.Count / [Math]::Max(1, $maximumWeek)
    $amplitude = [Math]::Pow($ratio, 0.62) * $mobileChartHeight
    [void]$mobilePoints.Add([PSCustomObject]@{
        X = [Int32][Math]::Round($mobileLeft + ($index * $mobileSpacing))
        Y = [Int32][Math]::Round($mobileBaseline - $amplitude)
        Start = $week.Start
        End = $week.End
        Count = $week.Count
    })
}

$mobileFirst = $mobilePoints[0]
$mobileLast = $mobilePoints[$mobilePoints.Count - 1]
$mobileSignalPath = "M $($mobileFirst.X) $($mobileFirst.Y)"
$mobileAreaPath = "M $($mobileFirst.X) $mobileBaseline L $($mobileFirst.X) $($mobileFirst.Y)"
for ($index = 1; $index -lt $mobilePoints.Count; $index++) {
    $previous = $mobilePoints[$index - 1]
    $current = $mobilePoints[$index]
    $controlX = [Int32][Math]::Round(($previous.X + $current.X) / 2)
    $curve = " C $controlX $($previous.Y), $controlX $($current.Y), $($current.X) $($current.Y)"
    $mobileSignalPath += $curve
    $mobileAreaPath += $curve
}
$mobileAreaPath += " L $($mobileLast.X) $mobileBaseline Z"

$mobileMonths = [System.Collections.Generic.List[object]]::new()
$seenMobileMonths = @{}
foreach ($point in $mobilePoints) {
    $monthKey = $point.Start.ToString("yyyy-MM")
    if (-not $seenMobileMonths.ContainsKey($monthKey)) {
        $seenMobileMonths[$monthKey] = $true
        [void]$mobileMonths.Add([PSCustomObject]@{
            X = $point.X
            Label = $point.Start.ToString("MMM", [System.Globalization.CultureInfo]::InvariantCulture).ToUpperInvariant()
        })
    }
}

$mobileSvg = [System.Collections.Generic.List[string]]::new()
[void]$mobileSvg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="540" height="520" viewBox="0 0 540 520" role="img" aria-labelledby="title desc">')
[void]$mobileSvg.Add('<title id="title">Annual contribution rhythm</title>')
[void]$mobileSvg.Add('<desc id="desc">A mobile contribution signal route across the last year.</desc>')
[void]$mobileSvg.Add('<rect width="540" height="520" rx="8" fill="#16171d"/>')
[void]$mobileSvg.Add('<rect x="1" y="1" width="538" height="518" rx="7" fill="none" stroke="#393c46"/>')
[void]$mobileSvg.Add('<text x="32" y="43" fill="#f4f1ea" font-family="Arial Black,Arial,sans-serif" font-size="22">BUILD RHYTHM</text>')
[void]$mobileSvg.Add('<text x="32" y="66" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="12">365 DAYS / WEEKLY ACTIVITY SIGNAL</text>')

for ($index = 0; $index -lt $summary.Count; $index++) {
    $entry = $summary[$index]
    $column = $index % 2
    $row = [Int32][Math]::Floor($index / 2)
    $x = 32 + ($column * 254)
    $labelY = 106 + ($row * 70)
    $valueY = $labelY + 29
    [void]$mobileSvg.Add(('<text x="{0}" y="{1}" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="11">{2}</text>' -f $x, $labelY, $entry.Label))
    [void]$mobileSvg.Add(('<text x="{0}" y="{1}" fill="{2}" font-family="Cascadia Mono,Consolas,monospace" font-size="25" font-weight="700">{3}</text>' -f $x, $valueY, $entry.Color, $entry.Value))
}

[void]$mobileSvg.Add('<line x1="32" y1="222" x2="508" y2="222" stroke="#393c46"/>')
[void]$mobileSvg.Add('<text x="32" y="248" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="11">WEEKLY SIGNAL ROUTE</text>')
[void]$mobileSvg.Add('<line x1="32" y1="350" x2="508" y2="350" stroke="#2b2e37" stroke-dasharray="3 9"/>')
[void]$mobileSvg.Add('<line x1="32" y1="402" x2="508" y2="402" stroke="#454955"/>')
[void]$mobileSvg.Add(('<path d="{0}" fill="#203a43" fill-opacity="0.46"/>' -f $mobileAreaPath))
[void]$mobileSvg.Add(('<path d="{0}" fill="none" stroke="#69d2e7" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>' -f $mobileSignalPath))

foreach ($point in $mobilePoints) {
    $color = Get-SignalColor $point.Count $maximumWeek
    $radius = if ($point.Count -eq 0) { 2 } else { 4 + [Int32][Math]::Round(7 * [Math]::Pow(($point.Count / [Math]::Max(1, $maximumWeek)), 0.65)) }
    [void]$mobileSvg.Add(('<circle cx="{0}" cy="{1}" r="{2}" fill="{3}" stroke="#16171d" stroke-width="2"><title>{4} to {5}: {6} contributions</title></circle>' -f $point.X, $point.Y, $radius, $color, $point.Start.ToString("yyyy-MM-dd"), $point.End.ToString("yyyy-MM-dd"), $point.Count))
}

$mobilePeak = @($mobilePoints | Where-Object { $_.Start -eq $peakWeek.Start } | Select-Object -First 1)[0]
$mobilePeakLabelY = [Int32][Math]::Max(269, ($mobilePeak.Y - 22))
[void]$mobileSvg.Add(('<line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#ff8a65" stroke-width="1"/>' -f $mobilePeak.X, ($mobilePeak.Y - 7), ($mobilePeakLabelY + 5)))
[void]$mobileSvg.Add(('<text x="{0}" y="{1}" fill="#ff8a65" font-family="Cascadia Mono,Consolas,monospace" font-size="11" font-weight="700" text-anchor="middle">PEAK / {2}</text>' -f $mobilePeak.X, $mobilePeakLabelY, (Format-Number $mobilePeak.Count)))

for ($index = 0; $index -lt $mobileMonths.Count; $index++) {
    if (($index % 2 -eq 0) -or ($index -eq ($mobileMonths.Count - 1))) {
        $marker = $mobileMonths[$index]
        [void]$mobileSvg.Add(('<line x1="{0}" y1="407" x2="{0}" y2="412" stroke="#5a6170"/>' -f $marker.X))
        [void]$mobileSvg.Add(('<text x="{0}" y="436" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="10" text-anchor="middle">{1}</text>' -f $marker.X, $marker.Label))
    }
}

[void]$mobileSvg.Add('<text x="32" y="482" fill="#727887" font-family="Cascadia Mono,Consolas,monospace" font-size="10">LOW</text>')
for ($index = 0; $index -lt 4; $index++) {
    $legendX = 68 + ($index * 20)
    $legendCount = [Math]::Max(1, [Math]::Ceiling($maximumWeek * ($index + 1) / 4))
    [void]$mobileSvg.Add(('<circle cx="{0}" cy="479" r="5" fill="{1}"/>' -f $legendX, (Get-SignalColor $legendCount $maximumWeek)))
}
[void]$mobileSvg.Add('<text x="153" y="482" fill="#727887" font-family="Cascadia Mono,Consolas,monospace" font-size="10">HIGH</text>')
[void]$mobileSvg.Add('<text x="32" y="504" fill="#727887" font-family="Cascadia Mono,Consolas,monospace" font-size="10">REAL WEEKLY TOTALS / NO SYNTHETIC ACTIVITY</text>')
[void]$mobileSvg.Add('</svg>')
Write-Svg "contributions-mobile.svg" $mobileSvg

$activitySvg = [System.Collections.Generic.List[string]]::new()
[void]$activitySvg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="540" height="280" viewBox="0 0 540 280" role="img" aria-labelledby="title desc">')
[void]$activitySvg.Add('<title id="title">Monthly contribution chapters</title>')
[void]$activitySvg.Add('<desc id="desc">Monthly contribution totals for the last year.</desc>')
[void]$activitySvg.Add('<rect width="540" height="280" rx="8" fill="#16171d"/>')
[void]$activitySvg.Add('<rect x="1" y="1" width="538" height="278" rx="7" fill="none" stroke="#393c46"/>')
[void]$activitySvg.Add('<text x="30" y="42" fill="#f4f1ea" font-family="Arial Black,Arial,sans-serif" font-size="18">MONTHLY CHAPTERS</text>')
[void]$activitySvg.Add(('<text x="30" y="66" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="12">PEAK / {0} / {1} CONTRIBUTIONS</text>' -f $mostActiveMonth.Label.ToUpperInvariant(), (Format-Number $mostActiveMonth.Count)))

$chartLeft = 36
$chartBottom = 224
$chartHeight = 128
$barWidth = 22
$barGap = 15
for ($index = 0; $index -lt $monthData.Count; $index++) {
    $month = $monthData[$index]
    $height = [Math]::Round($chartHeight * $month.Count / [Math]::Max(1, $maximumMonth))
    $x = $chartLeft + ($index * ($barWidth + $barGap))
    $y = $chartBottom - $height
    $barColor = Get-SignalColor $month.Count $maximumMonth
    [void]$activitySvg.Add(('<rect x="{0}" y="{1}" width="{2}" height="{3}" rx="3" fill="{4}"><title>{5}: {6} contributions</title></rect>' -f $x, $y, $barWidth, $height, $barColor, $month.Label, $month.Count))
    [void]$activitySvg.Add(('<text x="{0}" y="247" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="10" text-anchor="middle">{1}</text>' -f ($x + 11), $month.Label))
}
[void]$activitySvg.Add('<line x1="30" y1="224" x2="510" y2="224" stroke="#454955"/>')
[void]$activitySvg.Add('</svg>')
Write-Svg "activity.svg" $activitySvg

$languageMap = @{}
foreach ($repository in $user.repositories.nodes) {
    if ($repository.isFork) {
        continue
    }
    foreach ($edge in $repository.languages.edges) {
        $name = $edge.node.name
        if (-not $languageMap.ContainsKey($name)) {
            $languageMap[$name] = [PSCustomObject]@{
                Name = $name
                Color = if ($edge.node.color) { $edge.node.color } else { "#a6adbb" }
                Bytes = [Int64]0
            }
        }
        $languageMap[$name].Bytes += [Int64]$edge.size
    }
}

$languages = @($languageMap.Values | Sort-Object Bytes -Descending | Select-Object -First 5)
$languageTotal = [Int64](($languageMap.Values | Measure-Object -Property Bytes -Sum).Sum)

$languagesSvg = [System.Collections.Generic.List[string]]::new()
[void]$languagesSvg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="540" height="280" viewBox="0 0 540 280" role="img" aria-labelledby="title desc">')
[void]$languagesSvg.Add('<title id="title">Public repository language distribution</title>')
[void]$languagesSvg.Add('<desc id="desc">Most used programming languages across public repositories.</desc>')
[void]$languagesSvg.Add('<rect width="540" height="280" rx="8" fill="#16171d"/>')
[void]$languagesSvg.Add('<rect x="1" y="1" width="538" height="278" rx="7" fill="none" stroke="#393c46"/>')
[void]$languagesSvg.Add('<text x="30" y="42" fill="#f4f1ea" font-family="Arial Black,Arial,sans-serif" font-size="18">PUBLIC REPOSITORY LANGUAGES</text>')
[void]$languagesSvg.Add('<text x="30" y="66" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="12">MEASURED BY TRACKED SOURCE SIZE</text>')

if ($languages.Count -eq 0) {
    [void]$languagesSvg.Add('<text x="30" y="130" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="14">No public language data is available yet.</text>')
}
else {
    for ($index = 0; $index -lt $languages.Count; $index++) {
        $language = $languages[$index]
        $y = 100 + ($index * 31)
        $percent = [Math]::Round((100 * $language.Bytes / [Math]::Max(1, $languageTotal)), 1)
        $barWidth = [Math]::Round(255 * $language.Bytes / [Math]::Max(1, $languages[0].Bytes))
        [void]$languagesSvg.Add(('<circle cx="36" cy="{0}" r="6" fill="{1}"/>' -f ($y - 4), $language.Color))
        [void]$languagesSvg.Add(('<text x="52" y="{0}" fill="#d9dde7" font-family="Segoe UI,Arial,sans-serif" font-size="13">{1}</text>' -f $y, $language.Name))
        [void]$languagesSvg.Add(('<rect x="190" y="{0}" width="270" height="10" rx="5" fill="#2b2e37"/>' -f ($y - 11)))
        [void]$languagesSvg.Add(('<rect x="190" y="{0}" width="{1}" height="10" rx="5" fill="{2}"/>' -f ($y - 11), $barWidth, $language.Color))
        [void]$languagesSvg.Add(('<text x="484" y="{0}" fill="#a6adbb" font-family="Cascadia Mono,Consolas,monospace" font-size="12" text-anchor="end">{1}%</text>' -f $y, $percent.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)))
    }
}
[void]$languagesSvg.Add('</svg>')
Write-Svg "languages.svg" $languagesSvg

Write-Host "Generated profile assets for $Username in $outputDirectory"
