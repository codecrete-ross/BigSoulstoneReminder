param(
    [string]$WoWAddOnsRoot,
    [string]$WoWInstallRoot
)

$ErrorActionPreference = "Stop"

if ($WoWAddOnsRoot -and $WoWInstallRoot) {
    throw "Specify either -WoWAddOnsRoot or -WoWInstallRoot."
}

function Get-WoWInstallCandidates {
    if ($WoWInstallRoot) {
        $WoWInstallRoot
        return
    }

    $registryKeys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
        'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft',
        'HKCU:\Software\Blizzard Entertainment\World of Warcraft'
    )

    foreach ($key in $registryKeys) {
        $registryEntry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        $installPath = $registryEntry.InstallPath
        if ($installPath -and (Test-Path -LiteralPath $installPath -PathType Container)) {
            $installDirectory = Get-Item -LiteralPath $installPath
            if ($installDirectory.Name -match '^_.+_$') {
                $installDirectory = $installDirectory.Parent
            }
            $installDirectory.FullName
        }
    }

    foreach ($programFiles in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($programFiles) {
            Join-Path $programFiles 'World of Warcraft'
        }
    }
}

$addOnsRoots = if ($WoWAddOnsRoot) {
    $WoWAddOnsRoot
} else {
    $installCandidates = @(Get-WoWInstallCandidates)
    foreach ($flavor in @('_retail_', '_forever_')) {
        foreach ($installCandidate in $installCandidates) {
            $clientRoot = Join-Path $installCandidate $flavor
            if (Test-Path -LiteralPath (Join-Path $clientRoot 'Wow.exe') -PathType Leaf) {
                Join-Path $clientRoot 'Interface\AddOns'
                break
            }
        }
    }
}

if (-not $addOnsRoots) {
    throw 'Could not find a Retail or Forever installation. Specify -WoWInstallRoot or -WoWAddOnsRoot.'
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$addonName = 'BigSoulstoneReminder'
$tocFile = "$addonName.toc"

$sourceFiles = foreach ($file in @("$addonName.lua", 'logo.tga', 'CHANGELOG.md')) {
    $source = Join-Path $projectRoot $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Missing addon file $source"
    }
    $source
}

$versionHeading = Select-String -LiteralPath (Join-Path $projectRoot 'CHANGELOG.md') -Pattern '^## (\d+\.\d+\.\d+)\s*$' | Select-Object -First 1
if (-not $versionHeading) {
    throw 'Could not read the release version from CHANGELOG.md.'
}
$version = $versionHeading.Matches[0].Groups[1].Value
$toc = [System.IO.File]::ReadAllText((Join-Path $projectRoot $tocFile))
$deployedToc = $toc.Replace('@project-version@', $version)

foreach ($addOnsRoot in $addOnsRoots) {
    $destination = Join-Path $addOnsRoot $addonName
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -LiteralPath $sourceFiles -Destination $destination -Force
    $destinationToc = Join-Path $destination $tocFile
    [System.IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($destinationToc), $deployedToc)
    Write-Host "Deployed $addonName $version to $destination"
}
