<#
Disclaimer: This sample script is not supported under any Microsoft standard support program or service.
It is provided "AS IS", without warranties or conditions of any kind, either express or implied,
including warranties of merchantability, fitness for a particular purpose, and non-infringement.
You assume all risks associated with its use, execution, and performance. You are responsible for
reviewing and testing the script and validating its suitability for your environment before use.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Path,

    [Parameter(Mandatory)]
    [ValidateSet('major', 'minor', 'patch')]
    [string]$Bump
)

$versionPattern = '(?m)^(?<prefix>[ \t]*Version:[ \t]*)(?<version>\d+\.\d+\.\d+)(?<suffix>[ \t]*\r?)$'

foreach ($scriptPath in $Path) {
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Script not found: $scriptPath"
    }

    $resolvedPath = (Resolve-Path -LiteralPath $scriptPath).Path
    $content = [System.IO.File]::ReadAllText($resolvedPath)
    $matches = [regex]::Matches($content, $versionPattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one Version entry in $scriptPath, found $($matches.Count)."
    }

    $currentVersion = [version]$matches[0].Groups['version'].Value
    $nextVersion = switch ($Bump) {
        'major' { [version]::new($currentVersion.Major + 1, 0, 0) }
        'minor' { [version]::new($currentVersion.Major, $currentVersion.Minor + 1, 0) }
        'patch' { [version]::new($currentVersion.Major, $currentVersion.Minor, $currentVersion.Build + 1) }
    }

    $replacement = [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        "$($match.Groups['prefix'].Value)$nextVersion$($match.Groups['suffix'].Value)"
    }
    $updatedContent = [regex]::Replace($content, $versionPattern, $replacement)
    [System.IO.File]::WriteAllText($resolvedPath, $updatedContent)
    Write-Output "${scriptPath}: $currentVersion -> $nextVersion"
}