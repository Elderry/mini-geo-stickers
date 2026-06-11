<#
.SYNOPSIS
Copies selected source SVG files into the output folder.

.DESCRIPTION
Scans the project for SVG files with <metadata><output>true</output></metadata>
and copies them into the output folder while preserving their relative paths.
#>

$SourceRoot = $PSScriptRoot
$OutputRoot = (Join-Path $PSScriptRoot 'output')

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

$sourceRootPath = [System.IO.Path]::GetFullPath($SourceRoot)
$outputRootPath = [System.IO.Path]::GetFullPath($OutputRoot)

$generated = @()
$sourceFiles = Get-ChildItem -Path $sourceRootPath -Filter '*.svg' -Recurse -File

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

    Copy-Item -LiteralPath $sourceFile.FullName -Destination $outputPath -Force
    $generated += $outputPath
}

if ($generated.Count -eq 0) {
    Write-Host 'No SVG files opted in with <metadata><output>true</output></metadata>.'
} else {
    Write-Host "Copied $($generated.Count) SVG file(s):"
    foreach ($path in $generated) {
        Write-Host "  $path"
    }
}
