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
            weekday
            contributionCount
          }
        }
      }
    }
    repositories(first: 100, ownerAffiliations: OWNER, privacy: PUBLIC, orderBy: {field: UPDATED_AT, direction: DESC}) {
      totalCount
      nodes {
        isFork
        stargazerCount
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

function Get-HeatColor([Int64]$Count, [Int64]$Maximum) {
    if ($Count -le 0) { return "#21262d" }

    $ratio = $Count / [Math]::Max(1, $Maximum)
    if ($ratio -le 0.25) { return "#0e4429" }
    if ($ratio -le 0.50) { return "#006d32" }
    if ($ratio -le 0.75) { return "#26a641" }
    return "#39d353"
}

function Write-Svg([string]$FileName, [System.Collections.Generic.List[string]]$Lines) {
    $path = Join-Path $outputDirectory $FileName
    [System.IO.File]::WriteAllText($path, ($Lines -join "`n"), [System.Text.UTF8Encoding]::new($false))
}

$totalContributions = [Int64]$calendar.totalContributions
$activeDays = @($days | Where-Object { [Int64]$_.contributionCount -gt 0 }).Count
$maximumDaily = [Int64](($days | Measure-Object -Property contributionCount -Maximum).Maximum)
$longestStreak = 0
$currentStreak = 0
foreach ($day in $days) {
    if ([Int64]$day.contributionCount -gt 0) {
        $currentStreak++
        $longestStreak = [Math]::Max($longestStreak, $currentStreak)
    }
    else {
        $currentStreak = 0
    }
}

$contributionSvg = [System.Collections.Generic.List[string]]::new()
[void]$contributionSvg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="1080" height="356" viewBox="0 0 1080 356" role="img" aria-labelledby="title desc">')
[void]$contributionSvg.Add('<title id="title">GitHub contribution overview</title>')
[void]$contributionSvg.Add('<desc id="desc">A one year contribution calendar and activity summary.</desc>')
[void]$contributionSvg.Add('<rect width="1080" height="356" rx="8" fill="#0d1117"/>')
[void]$contributionSvg.Add('<rect x="1" y="1" width="1078" height="354" rx="7" fill="none" stroke="#30363d"/>')
[void]$contributionSvg.Add(('<text x="42" y="46" fill="#f0f6fc" font-family="Segoe UI,Arial,sans-serif" font-size="22" font-weight="700">{0} / ACTIVITY PULSE</text>' -f $Username.ToUpperInvariant()))
[void]$contributionSvg.Add('<text x="42" y="70" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="13">LAST 365 DAYS</text>')

$summary = @(
    [PSCustomObject]@{ Label = "CONTRIBUTIONS"; Value = (Format-Number $totalContributions); Color = "#39d353" },
    [PSCustomObject]@{ Label = "ACTIVE DAYS"; Value = (Format-Number $activeDays); Color = "#58a6ff" },
    [PSCustomObject]@{ Label = "LONGEST RUN"; Value = ("{0} days" -f $longestStreak); Color = "#d29922" },
    [PSCustomObject]@{ Label = "PUBLIC REPOS"; Value = (Format-Number ([Int64]$user.repositories.totalCount)); Color = "#f778ba" }
)

for ($index = 0; $index -lt $summary.Count; $index++) {
    $entry = $summary[$index]
    $x = 42 + ($index * 252)
    [void]$contributionSvg.Add(('<text x="{0}" y="112" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12" font-weight="700">{1}</text>' -f $x, $entry.Label))
    [void]$contributionSvg.Add(('<text x="{0}" y="151" fill="{1}" font-family="Segoe UI,Arial,sans-serif" font-size="31" font-weight="700">{2}</text>' -f $x, $entry.Color, $entry.Value))
    if ($index -lt ($summary.Count - 1)) {
        $lineX = $x + 220
        [void]$contributionSvg.Add(('<line x1="{0}" y1="96" x2="{0}" y2="154" stroke="#30363d"/>' -f $lineX))
    }
}

$calendarX = 142
$calendarY = 198
$cell = 12
$gap = 4
$weekdayLabels = @("SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT")
for ($index = 0; $index -lt $weekdayLabels.Count; $index++) {
    $y = $calendarY + ($index * ($cell + $gap)) + 10
    [void]$contributionSvg.Add(('<text x="96" y="{0}" fill="#6e7681" font-family="Segoe UI,Arial,sans-serif" font-size="10">{1}</text>' -f $y, $weekdayLabels[$index]))
}

for ($weekIndex = 0; $weekIndex -lt $calendar.weeks.Count; $weekIndex++) {
    foreach ($day in $calendar.weeks[$weekIndex].contributionDays) {
        $x = $calendarX + ($weekIndex * ($cell + $gap))
        $y = $calendarY + ([Int32]$day.weekday * ($cell + $gap))
        $color = Get-HeatColor ([Int64]$day.contributionCount) $maximumDaily
        [void]$contributionSvg.Add(('<rect x="{0}" y="{1}" width="{2}" height="{2}" rx="2" fill="{3}"><title>{4}: {5} contributions</title></rect>' -f $x, $y, $cell, $color, $day.date, $day.contributionCount))
    }
}

[void]$contributionSvg.Add('<text x="42" y="333" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12">Contribution intensity</text>')
for ($index = 0; $index -lt 5; $index++) {
    $legendX = 190 + ($index * 22)
    $legendCount = if ($index -eq 0) { 0 } else { [Math]::Max(1, [Math]::Ceiling($maximumDaily * $index / 4)) }
    $legendColor = Get-HeatColor $legendCount $maximumDaily
    [void]$contributionSvg.Add(('<rect x="{0}" y="321" width="14" height="14" rx="2" fill="{1}"/>' -f $legendX, $legendColor))
}
[void]$contributionSvg.Add('<text x="307" y="333" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12">Less</text>')
[void]$contributionSvg.Add('<text x="344" y="333" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12">More</text>')
[void]$contributionSvg.Add('</svg>')
Write-Svg "contributions.svg" $contributionSvg

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

$activitySvg = [System.Collections.Generic.List[string]]::new()
[void]$activitySvg.Add('<svg xmlns="http://www.w3.org/2000/svg" width="540" height="280" viewBox="0 0 540 280" role="img" aria-labelledby="title desc">')
[void]$activitySvg.Add('<title id="title">Contribution cadence</title>')
[void]$activitySvg.Add('<desc id="desc">Monthly contribution totals for the last year.</desc>')
[void]$activitySvg.Add('<rect width="540" height="280" rx="8" fill="#0d1117"/>')
[void]$activitySvg.Add('<rect x="1" y="1" width="538" height="278" rx="7" fill="none" stroke="#30363d"/>')
[void]$activitySvg.Add('<text x="30" y="42" fill="#f0f6fc" font-family="Segoe UI,Arial,sans-serif" font-size="19" font-weight="700">CONTRIBUTION CADENCE</text>')
[void]$activitySvg.Add(('<text x="30" y="66" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12">Peak: {0} / {1} contributions</text>' -f $mostActiveMonth.Label, (Format-Number $mostActiveMonth.Count)))

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
    [void]$activitySvg.Add(('<rect x="{0}" y="{1}" width="{2}" height="{3}" rx="3" fill="#58a6ff"><title>{4}: {5} contributions</title></rect>' -f $x, $y, $barWidth, $height, $month.Label, $month.Count))
    [void]$activitySvg.Add(('<text x="{0}" y="247" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="10" text-anchor="middle">{1}</text>' -f ($x + 11), $month.Label))
}
[void]$activitySvg.Add('<line x1="30" y1="224" x2="510" y2="224" stroke="#30363d"/>')
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
                Color = if ($edge.node.color) { $edge.node.color } else { "#8b949e" }
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
[void]$languagesSvg.Add('<rect width="540" height="280" rx="8" fill="#0d1117"/>')
[void]$languagesSvg.Add('<rect x="1" y="1" width="538" height="278" rx="7" fill="none" stroke="#30363d"/>')
[void]$languagesSvg.Add('<text x="30" y="42" fill="#f0f6fc" font-family="Segoe UI,Arial,sans-serif" font-size="19" font-weight="700">PUBLIC REPOSITORY LANGUAGES</text>')
[void]$languagesSvg.Add('<text x="30" y="66" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12">Measured by tracked source size</text>')

if ($languages.Count -eq 0) {
    [void]$languagesSvg.Add('<text x="30" y="130" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="14">No public language data is available yet.</text>')
}
else {
    for ($index = 0; $index -lt $languages.Count; $index++) {
        $language = $languages[$index]
        $y = 100 + ($index * 31)
        $percent = [Math]::Round((100 * $language.Bytes / [Math]::Max(1, $languageTotal)), 1)
        $barWidth = [Math]::Round(255 * $language.Bytes / [Math]::Max(1, $languages[0].Bytes))
        [void]$languagesSvg.Add(('<circle cx="36" cy="{0}" r="6" fill="{1}"/>' -f ($y - 4), $language.Color))
        [void]$languagesSvg.Add(('<text x="52" y="{0}" fill="#c9d1d9" font-family="Segoe UI,Arial,sans-serif" font-size="13">{1}</text>' -f $y, $language.Name))
        [void]$languagesSvg.Add(('<rect x="190" y="{0}" width="270" height="10" rx="5" fill="#21262d"/>' -f ($y - 11)))
        [void]$languagesSvg.Add(('<rect x="190" y="{0}" width="{1}" height="10" rx="5" fill="{2}"/>' -f ($y - 11), $barWidth, $language.Color))
        [void]$languagesSvg.Add(('<text x="484" y="{0}" fill="#8b949e" font-family="Segoe UI,Arial,sans-serif" font-size="12" text-anchor="end">{1}%</text>' -f $y, $percent.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)))
    }
}
[void]$languagesSvg.Add('</svg>')
Write-Svg "languages.svg" $languagesSvg

Write-Host "Generated profile assets for $Username in $outputDirectory"
