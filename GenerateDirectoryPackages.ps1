param(
    [string]$Root = ".",
    [string]$OutputProps = "Directory.Packages.props",
    [string]$OutputOverrides = "PackageVersionOverrides.json"
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------
# Helper: PowerShell 5.1 compatible relative path
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
    ).Replace(
        '/',
        [System.IO.Path]::DirectorySeparatorChar
    )
}

# ----------------------------------------------------------------------
# Resolve repository root
# ----------------------------------------------------------------------

$rootPath = (Resolve-Path $Root).Path

Write-Host "Root: $rootPath"
Write-Host ""

# ----------------------------------------------------------------------
# Locate NuGet.Versioning.dll
#
# We use NuGet's own version parser/comparer so versions such as:
#
#   10.0.9
#   10.0.11
#   10.0.11-preview.1
#
# are compared correctly rather than alphabetically.
# ----------------------------------------------------------------------

$dotnetCommand = Get-Command dotnet -ErrorAction Stop
$dotnetExe = $dotnetCommand.Source
$dotnetRoot = Split-Path $dotnetExe -Parent

$nugetVersioningDll = Get-ChildItem `
    -Path $dotnetRoot `
    -Filter "NuGet.Versioning.dll" `
    -Recurse `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $nugetVersioningDll) {
    throw "Could not locate NuGet.Versioning.dll under '$dotnetRoot'."
}

Write-Host "Using NuGet.Versioning:"
Write-Host "  $($nugetVersioningDll.FullName)"
Write-Host ""

Add-Type -Path $nugetVersioningDll.FullName

# ----------------------------------------------------------------------
# Collect all explicit PackageReference versions
# ----------------------------------------------------------------------

$packages = @{}

$projectFiles = Get-ChildItem `
    -Path $rootPath `
    -Recurse `
    -Filter "*.csproj" |
Where-Object {
    $_.FullName -notmatch '[\\/](bin|obj)[\\/]'
}

foreach ($projectFile in $projectFiles) {

    $projectPath = $projectFile.FullName

    $relativeProjectPath = (
        Get-RelativePath `
            -BasePath $rootPath `
            -TargetPath $projectPath
    ).Replace('\', '/')

    $projectName = [System.IO.Path]::GetFileNameWithoutExtension(
        $projectPath
    )

    Write-Host "Scanning $relativeProjectPath"

    [xml]$xml = Get-Content -LiteralPath $projectPath

    $references = $xml.SelectNodes("//PackageReference")

    foreach ($reference in $references) {

        # --------------------------------------------------------------
        # Package name
        #
        # Normally:
        # <PackageReference Include="Some.Package" ... />
        #
        # but Update="..." is also supported.
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
        # Package version
        #
        # Supports:
        #
        # <PackageReference Include="X" Version="1.2.3" />
        #
        # and:
        #
        # <PackageReference Include="X">
        #   <Version>1.2.3</Version>
        # </PackageReference>
        # --------------------------------------------------------------

        $version = $null

        if ($reference.HasAttribute("Version")) {
            $version = $reference.GetAttribute("Version")
        }
        else {
            $versionNode = $reference.SelectSingleNode("Version")

            if ($versionNode) {
                $version = $versionNode.InnerText
            }
        }

        if ([string]::IsNullOrWhiteSpace($version)) {
            # Already centrally managed, or version comes from elsewhere.
            continue
        }

        $version = $version.Trim()

        # --------------------------------------------------------------
        # Skip MSBuild variables for now, e.g.
        #
        # Version="$(EfCoreVersion)"
        #
        # These cannot safely be resolved by this script without evaluating
        # the MSBuild project.
        # --------------------------------------------------------------

        if ($version -match '\$\(') {
            Write-Warning (
                "Skipping MSBuild version '{0}' for package '{1}' in '{2}'" `
                    -f $version, $packageName, $relativeProjectPath
            )

            continue
        }

        # --------------------------------------------------------------
        # Parse semantic NuGet version
        # --------------------------------------------------------------

        try {
            $parsedVersion =
                [NuGet.Versioning.NuGetVersion]::Parse($version)
        }
        catch {
            Write-Warning (
                "Skipping invalid NuGet version '{0}' for package '{1}' in '{2}'" `
                    -f $version, $packageName, $relativeProjectPath
            )

            continue
        }

        if (-not $packages.ContainsKey($packageName)) {
            $packages[$packageName] = @()
        }

        $packages[$packageName] += [PSCustomObject]@{
            Package       = $packageName
            Version       = $version
            ParsedVersion = $parsedVersion
            Project       = $projectName
            ProjectPath   = $relativeProjectPath
        }
    }
}

Write-Host ""
Write-Host "Projects scanned: $($projectFiles.Count)"
Write-Host "Distinct packages found: $($packages.Count)"
Write-Host ""

# ----------------------------------------------------------------------
# Determine highest version and collect lower/different versions
# ----------------------------------------------------------------------

$centralPackages = @()
$overrides = @()

foreach ($packageName in ($packages.Keys | Sort-Object)) {

    $entries = @($packages[$packageName])

    # NuGetVersion implements IComparable, so Sort-Object can compare it.
    $latest = $entries |
        Sort-Object `
            @{ Expression = { $_.ParsedVersion }; Descending = $true } |
        Select-Object -First 1

    $centralPackages += [PSCustomObject]@{
        Package = $packageName
        Version = $latest.Version
    }

    # Find every version different from the selected central version.
    $differentEntries = @(
        $entries |
        Where-Object {
            $_.ParsedVersion.CompareTo($latest.ParsedVersion) -ne 0
        }
    )

    if ($differentEntries.Count -gt 0) {

        $overrideVersions = @()

        $versionGroups = $differentEntries |
            Group-Object Version |
            Sort-Object Name

        foreach ($group in $versionGroups) {

            $projects = @(
                $group.Group |
                Sort-Object ProjectPath -Unique |
                ForEach-Object {
                    [PSCustomObject]@{
                        Name = $_.Project
                        Path = $_.ProjectPath
                    }
                }
            )

            $overrideVersions += [PSCustomObject]@{
                Version  = $group.Name
                Projects = $projects
            }
        }

        $overrides += [PSCustomObject]@{
            Package        = $packageName
            CentralVersion = $latest.Version
            OtherVersions  = $overrideVersions
        }
    }
}

# ----------------------------------------------------------------------
# Generate Directory.Packages.props
# ----------------------------------------------------------------------

$propsPath = Join-Path $rootPath $OutputProps

$xmlSettings = New-Object System.Xml.XmlWriterSettings
$xmlSettings.Indent = $true
$xmlSettings.IndentChars = "  "
$xmlSettings.NewLineChars = [Environment]::NewLine
$xmlSettings.NewLineHandling = "Replace"
$xmlSettings.Encoding = New-Object System.Text.UTF8Encoding($false)

$writer = [System.Xml.XmlWriter]::Create(
    $propsPath,
    $xmlSettings
)

try {
    $writer.WriteStartDocument()

    $writer.WriteStartElement("Project")

    $writer.WriteStartElement("PropertyGroup")

    $writer.WriteElementString(
        "ManagePackageVersionsCentrally",
        "true"
    )

    $writer.WriteEndElement() # PropertyGroup

    $writer.WriteStartElement("ItemGroup")

    foreach ($package in $centralPackages) {

        $writer.WriteStartElement("PackageVersion")

        $writer.WriteAttributeString(
            "Include",
            $package.Package
        )

        $writer.WriteAttributeString(
            "Version",
            $package.Version
        )

        $writer.WriteEndElement()
    }

    $writer.WriteEndElement() # ItemGroup

    $writer.WriteEndElement() # Project

    $writer.WriteEndDocument()
}
finally {
    if ($writer) {
        $writer.Dispose()
    }
}

# ----------------------------------------------------------------------
# Generate PackageVersionOverrides.json
# ----------------------------------------------------------------------

$overridePath = Join-Path $rootPath $OutputOverrides

$overrideOutput = [PSCustomObject]@{
    FormatVersion = 1
    GeneratedAt   = (Get-Date).ToString("o")
    Root          = "."
    Packages      = @($overrides)
}

$overrideJson = $overrideOutput |
    ConvertTo-Json -Depth 10

[System.IO.File]::WriteAllText(
    $overridePath,
    $overrideJson,
    (New-Object System.Text.UTF8Encoding($false))
)

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

Write-Host ""
Write-Host "Generated:"
Write-Host "  $OutputProps"
Write-Host "  $OutputOverrides"
Write-Host ""
Write-Host "Central package versions: $($centralPackages.Count)"
Write-Host "Packages with conflicting versions: $($overrides.Count)"
Write-Host ""

if ($overrides.Count -gt 0) {

    Write-Host "Packages with multiple versions:"

    foreach ($override in $overrides) {
        Write-Host (
            "  {0}: central={1}" `
                -f $override.Package, $override.CentralVersion
        )
    }
}

Write-Host ""
Write-Host "Done."