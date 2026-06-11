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
    $document.PreserveWhitespace = $false
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

function Get-ElementById {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$Id
    )

    foreach ($element in $Document.GetElementsByTagName('*')) {
        if ($element.HasAttribute('id') -and $element.GetAttribute('id') -eq $Id) {
            return $element
        }
    }

    return $null
}

function Get-OrCreateDefsElement {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)

    $defs = Get-DirectChildElement -Parent $Document.DocumentElement -LocalName 'defs'
    if ($null -ne $defs) {
        return $defs
    }

    $defs = $Document.CreateElement('defs', $Document.DocumentElement.NamespaceURI)
    [void]$Document.DocumentElement.InsertBefore($defs, $Document.DocumentElement.FirstChild)
    return $defs
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
        $style.InnerText = "`n" + (Get-Content -LiteralPath $stylesheetPath -Raw).TrimEnd() + "`n"
        [void]$Document.DocumentElement.InsertBefore($style, $Document.DocumentElement.FirstChild)
        [void]$Document.RemoveChild($instruction)
    }
}

function Inline-ExternalPaintServers {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $urlPattern = 'url\(([''\"]?)(?<href>[^#)''\"]+\.svg)#(?<id>[^)''\"]+)\1\)'
    $references = [ordered]@{}

    foreach ($element in $Document.GetElementsByTagName('*')) {
        foreach ($attribute in @($element.Attributes)) {
            foreach ($match in [regex]::Matches($attribute.Value, $urlPattern)) {
                $href = $match.Groups['href'].Value
                $id = $match.Groups['id'].Value
                $assetPath = Resolve-AssetPath -BasePath $SourcePath -Href $href

                if ($null -eq $assetPath) {
                    continue
                }

                $references["$assetPath#$id"] = [pscustomobject]@{
                    Path = $assetPath
                    Id = $id
                }
                $attribute.Value = $attribute.Value.Replace($match.Value, "url(#$id)")
            }
        }
    }

    foreach ($reference in $references.Values) {
        if (Get-ElementById -Document $Document -Id $reference.Id) {
            continue
        }

        if (-not (Test-Path -LiteralPath $reference.Path)) {
            Write-Warning "Paint server not found: $($reference.Path)#$($reference.Id)"
            continue
        }

        $assetDocument = Read-XmlDocument -Path $reference.Path
        $assetElement = Get-ElementById -Document $assetDocument -Id $reference.Id
        if ($null -eq $assetElement) {
            Write-Warning "Paint server id not found: $($reference.Id)"
            continue
        }

        $defs = Get-OrCreateDefsElement -Document $Document
        [void]$defs.AppendChild($Document.ImportNode($assetElement, $true))
    }
}

function Normalize-ElementAttributes {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Element)

    foreach ($attribute in @($Element.Attributes)) {
        if ($attribute.Name -eq 'd') {
            $attribute.Value = ([regex]::Replace($attribute.Value, '\s+', ' ')).Trim()
        }
    }

    foreach ($child in $Element.ChildNodes) {
        if ($child.NodeType -eq [System.Xml.XmlNodeType]::Element) {
            Normalize-ElementAttributes -Element $child
        }
    }
}

function Inline-SvgImages {
    param(
        [Parameter(Mandatory)][System.Xml.XmlDocument]$Document,
        [Parameter(Mandatory)][string]$SourcePath
    )

    $imageElements = @()
    foreach ($element in $Document.GetElementsByTagName('*')) {
        if ($element.LocalName -eq 'image') {
            $imageElements += $element
        }
    }

    foreach ($image in $imageElements) {
        $href = $image.GetAttribute('href')
        if ([string]::IsNullOrWhiteSpace($href)) {
            $href = $image.GetAttribute('href', 'http://www.w3.org/1999/xlink')
        }

        if ([string]::IsNullOrWhiteSpace($href) -or -not $href.EndsWith('.svg', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $assetPath = Resolve-AssetPath -BasePath $SourcePath -Href $href
        if ($null -eq $assetPath -or -not (Test-Path -LiteralPath $assetPath)) {
            Write-Warning "SVG image not found: $href"
            continue
        }

        $assetDocument = Read-XmlDocument -Path $assetPath
        $assetSvg = $assetDocument.DocumentElement
        Normalize-ElementAttributes -Element $assetSvg
        $inlineSvg = $Document.CreateElement('svg', $Document.DocumentElement.NamespaceURI)

        foreach ($attribute in @($image.Attributes)) {
            if ($attribute.LocalName -eq 'href') {
                continue
            }

            if ([string]::IsNullOrWhiteSpace($attribute.NamespaceURI)) {
                $inlineSvg.SetAttribute($attribute.Name, $attribute.Value)
            } else {
                $inlineSvg.SetAttribute($attribute.LocalName, $attribute.NamespaceURI, $attribute.Value)
            }
        }

        if ($assetSvg.HasAttribute('viewBox') -and -not $inlineSvg.HasAttribute('viewBox')) {
            $inlineSvg.SetAttribute('viewBox', $assetSvg.GetAttribute('viewBox'))
        }

        foreach ($child in $assetSvg.ChildNodes) {
            [void]$inlineSvg.AppendChild($Document.ImportNode($child, $true))
        }

        [void]$image.ParentNode.ReplaceChild($inlineSvg, $image)
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

    Inline-ExternalPaintServers -Document $document -SourcePath $sourceFile.FullName
    Inline-Stylesheets -Document $document -SourcePath $sourceFile.FullName
    Inline-SvgImages -Document $document -SourcePath $sourceFile.FullName
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
