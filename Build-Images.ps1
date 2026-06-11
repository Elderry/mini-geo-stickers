<#
.SYNOPSIS
Generates selected SVG files into the output folder.

.DESCRIPTION
Scans the project for SVG files with <metadata><output>true</output></metadata>
and writes them into the output folder while preserving their relative paths.
#>

$SourceFolders = @('cube', 'logo')
$OutputFolder = 'output'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-XmlDocument {
    param([Parameter(Mandatory)][string]$Path)

    $document = [System.Xml.XmlDocument]::new()
    $document.PreserveWhitespace = $true
    $document.Load($Path)
    return $document
}

function Get-DirectChildElement {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Parent,
        [Parameter(Mandatory)][string]$LocalName
    )

    foreach ($child in $Parent.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element -and $child.LocalName -eq $LocalName) {
            return $child
        }
    }

    return $null
}

function Test-OutputEnabled {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)

    $metadata = Get-DirectChildElement -Parent $Document.DocumentElement -LocalName 'metadata'
    if ($null -eq $metadata) {
        return $false
    }

    foreach ($output in $metadata.GetElementsByTagName('output')) {
        if ($output.InnerText.Trim().Equals('true', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Resolve-AssetPath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Href
    )

    if ([System.Uri]::IsWellFormedUriString($Href, [System.UriKind]::Absolute)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $BasePath) $Href))
}

function Get-StylesheetHref {
    param([Parameter(Mandatory)][System.Xml.XmlProcessingInstruction]$Instruction)

    $match = [regex]::Match($Instruction.Data, 'href\s*=\s*[''\"](?<href>[^''\"]+)[''\"]')
    if ($match.Success) {
        return $match.Groups['href'].Value
    }

    return $null
}

function Inline-Stylesheets {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $stylesheetInstructions = @()
    foreach ($child in $Document.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::ProcessingInstruction -and $child.Target -eq 'xml-stylesheet') {
            $stylesheetInstructions += $child
        }
    }

    foreach ($instruction in $stylesheetInstructions) {
        $href = Get-StylesheetHref -Instruction $instruction
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        $stylesheetPath = Resolve-AssetPath -BasePath $SourcePath -Href $href
        if ($null -eq $stylesheetPath -or -not (Test-Path -LiteralPath $stylesheetPath)) {
            Write-Warning "Stylesheet not found: $href"
            continue
        }

        $style = $Document.CreateElement('style', $Document.DocumentElement.NamespaceURI)
        $style.SetAttribute('type', 'text/css')
        [void]$style.AppendChild($Document.CreateCDataSection("`n" + (Get-Content -LiteralPath $stylesheetPath -Raw) + "`n"))
        [void]$Document.DocumentElement.InsertBefore($style, $Document.DocumentElement.FirstChild)
        [void]$Document.RemoveChild($instruction)
    }
}

function Save-XmlDocument {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$Path
    )

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)

    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $Document.Save($writer)
    } finally {
        $writer.Dispose()
    }
}

$sourceRootPath = [System.IO.Path]::GetFullPath($PSScriptRoot)
$outputRootPath = [System.IO.Path]::GetFullPath((Join-Path $sourceRootPath $OutputFolder))

$generated = @()
$sourceFolders = $SourceFolders | ForEach-Object { Join-Path $sourceRootPath $_ }
$sourceFiles = Get-ChildItem -Path $sourceFolders -Filter '*.svg' -Recurse -File

foreach ($sourceFile in $sourceFiles) {
    $document = Read-XmlDocument -Path $sourceFile.FullName
    if (-not (Test-OutputEnabled -Document $document)) {
        continue
    }

    $relativePath = [System.IO.Path]::GetRelativePath($sourceRootPath, $sourceFile.FullName)
    $outputPath = Join-Path $outputRootPath $relativePath
    $outputDirectory = Split-Path -Parent $outputPath

    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }

    Inline-Stylesheets -Document $document -SourcePath $sourceFile.FullName
    Save-XmlDocument -Document $document -Path $outputPath
    $generated += $outputPath
}

if ($generated.Count -eq 0) {
    Write-Host 'No SVG files opted in with <metadata><output>true</output></metadata>.'
} else {
    Write-Host "Generated $($generated.Count) SVG file(s):"
    foreach ($path in $generated) {
        Write-Host "  $path"
    }
}
