param(
    [string]$Root = ".",
    [string]$OverridesFile = "PackageVersionOverrides.json",
    [switch]$NoBackup
)

$ErrorActionPreference = "Stop"

$rootPath = (Resolve-Path $Root).Path
$overridesPath = Join-Path $rootPath $OverridesFile

if (-not (Test-Path -LiteralPath $overridesPath)) {
    throw "Override file not found: $overridesPath"
}

# ----------------------------------------------------------------------
# Load override information
# ----------------------------------------------------------------------

$overrideData =
    Get-Content -LiteralPath $overridesPath -Raw |
    ConvertFrom-Json

# Key:
#   normalized-relative-project-path | package-id
#
# Value:
#   overridden version
$overrideLookup = @{}

foreach ($packageEntry in $overrideData.Packages) {

    $packageName = [string]$packageEntry.Package

    foreach ($versionEntry in $packageEntry.OtherVersions) {

        $overrideVersion = [string]$versionEntry.Version

        foreach ($project in $versionEntry.Projects) {

            $projectPath = ([string]$project.Path).Replace('\', '/')
            $key = (
                $projectPath.ToLowerInvariant() +
                "|" +
                $packageName.ToLowerInvariant()
            )

            if ($overrideLookup.ContainsKey($key)) {
                throw "Duplicate override definition for $projectPath / $packageName"
            }

            $overrideLookup[$key] = $overrideVersion
        }
    }
}

# ----------------------------------------------------------------------
# PowerShell 5.1-compatible relative path helper
# ----------------------------------------------------------------------

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)

    if (-not $baseFullPath.EndsWith(
        [System.IO.Path]::DirectorySeparatorChar.ToString()
    )) {
        $baseFullPath += [System.IO.Path]::DirectorySeparatorChar
    }

    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)

    $baseUri = New-Object System.Uri($baseFullPath)
    $targetUri = New-Object System.Uri($targetFullPath)

    $relativeUri = $baseUri.MakeRelativeUri($targetUri)

    return [System.Uri]::UnescapeDataString(
        $relativeUri.ToString()
    ).Replace('/', '\')
}

# ----------------------------------------------------------------------
# Find projects
# ----------------------------------------------------------------------

$projects = @(
    Get-ChildItem `
        -Path $rootPath `
        -Recurse `
        -Filter "*.csproj" |
    Where-Object {
        $_.FullName -notmatch '[\\/](bin|obj)[\\/]'
    }
)

$totalReferences = 0
$centralizedReferences = 0
$overrideReferences = 0
$changedProjects = 0

foreach ($projectFile in $projects) {

    $projectFullPath = $projectFile.FullName

    $relativeProjectPath = (
        Get-RelativePath `
            -BasePath $rootPath `
            -TargetPath $projectFullPath
    ).Replace('\', '/')

    [xml]$xml = Get-Content -LiteralPath $projectFullPath

    $projectChanged = $false

    $packageReferences = @(
        $xml.SelectNodes("//PackageReference")
    )

    foreach ($reference in $packageReferences) {

        $totalReferences++

        # --------------------------------------------------------------
        # Identify package
        # --------------------------------------------------------------

        $packageName = $null

        if ($reference.HasAttribute("Include")) {
            $packageName = $reference.GetAttribute("Include")
        }
        elseif ($reference.HasAttribute("Update")) {
            $packageName = $reference.GetAttribute("Update")
        }

        if ([string]::IsNullOrWhiteSpace($packageName)) {
            continue
        }

        # --------------------------------------------------------------
        # Do not touch SDK-implicit package references.
        #
        # CPM treats these differently and may raise NU1009 if they are
        # managed centrally.
        # --------------------------------------------------------------

        if (
            $reference.HasAttribute("IsImplicitlyDefined") -and
            $reference.GetAttribute("IsImplicitlyDefined") -eq "true"
        ) {
            Write-Host "SKIP implicit: $relativeProjectPath :: $packageName"
            continue
        }

        # --------------------------------------------------------------
        # Determine whether this project/package has a recorded override
        # --------------------------------------------------------------

        $lookupKey = (
            $relativeProjectPath.ToLowerInvariant() +
            "|" +
            $packageName.ToLowerInvariant()
        )

        $hasOverride = $overrideLookup.ContainsKey($lookupKey)

        # --------------------------------------------------------------
        # Remove Version attribute
        # --------------------------------------------------------------

        if ($reference.HasAttribute("Version")) {
            $reference.RemoveAttribute("Version")
            $projectChanged = $true
        }

        # --------------------------------------------------------------
        # Remove child <Version>...</Version>
        # --------------------------------------------------------------

        $versionNode = $reference.SelectSingleNode("Version")

        if ($versionNode) {
            [void]$reference.RemoveChild($versionNode)
            $projectChanged = $true
        }

        # --------------------------------------------------------------
        # Apply override when the original project intentionally used
        # something other than the selected central version.
        # --------------------------------------------------------------

        if ($hasOverride) {

            $desiredVersion = [string]$overrideLookup[$lookupKey]

            if (
                -not $reference.HasAttribute("VersionOverride") -or
                $reference.GetAttribute("VersionOverride") -ne $desiredVersion
            ) {
                $reference.SetAttribute(
                    "VersionOverride",
                    $desiredVersion
                )

                $projectChanged = $true
            }

            $overrideReferences++

            Write-Host (
                "OVERRIDE: {0} :: {1} -> {2}" `
                    -f $relativeProjectPath,
                       $packageName,
                       $desiredVersion
            )
        }
        else {

            # No override was recorded, so this package must use
            # Directory.Packages.props.
            #
            # Remove stale VersionOverride metadata if present.
            if ($reference.HasAttribute("VersionOverride")) {
                $reference.RemoveAttribute("VersionOverride")
                $projectChanged = $true
            }

            $centralizedReferences++
        }
    }

    # ------------------------------------------------------------------
    # Save only changed projects
    # ------------------------------------------------------------------

    if ($projectChanged) {

        if (-not $NoBackup) {

            $backupPath = $projectFullPath + ".bak"

            Copy-Item `
                -LiteralPath $projectFullPath `
                -Destination $backupPath `
                -Force
        }

        # Preserve reasonably standard XML formatting.
        $settings = New-Object System.Xml.XmlWriterSettings
        $settings.Indent = $true
        $settings.IndentChars = "  "
        $settings.NewLineChars = [Environment]::NewLine
        $settings.NewLineHandling = "Replace"
        $settings.Encoding =
            New-Object System.Text.UTF8Encoding($false)

        $writer = [System.Xml.XmlWriter]::Create(
            $projectFullPath,
            $settings
        )

        try {
            $xml.Save($writer)
        }
        finally {
            $writer.Dispose()
        }

        $changedProjects++

        Write-Host "UPDATED: $relativeProjectPath"
    }
}

Write-Host ""
Write-Host "Completed."
Write-Host "Projects scanned:          $($projects.Count)"
Write-Host "Projects changed:          $changedProjects"
Write-Host "PackageReferences scanned: $totalReferences"
Write-Host "Centralized references:    $centralizedReferences"
Write-Host "Version overrides:         $overrideReferences"
Write-Host ""

if (-not $NoBackup) {
    Write-Host "Backup .csproj.bak files were created."
}