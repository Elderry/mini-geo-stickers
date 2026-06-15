<#
.SYNOPSIS
Generates selected image files into the output folder.

.DESCRIPTION
Scans the project for SVG files with <metadata><output>true</output></metadata>
and writes them into the output folder while preserving their relative paths.
Files can also request additional formats with <metadata><extra-format>PNG</extra-format></metadata>.
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

function Get-ExtraFormats {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)

    $metadata = Get-DirectChildElement -Parent $Document.DocumentElement -LocalName 'metadata'
    if ($null -eq $metadata) {
        return @()
    }

    $formats = [ordered]@{}
    foreach ($format in $metadata.GetElementsByTagName('extra-format')) {
        $normalizedFormat = $format.InnerText.Trim().ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($normalizedFormat)) {
            $formats[$normalizedFormat] = $true
        }
    }

    return @($formats.Keys)
}

function Get-VariantStyles {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)

    $metadata = Get-DirectChildElement -Parent $Document.DocumentElement -LocalName 'metadata'
    if ($null -eq $metadata) {
        return @()
    }

    $variants = [ordered]@{}
    foreach ($variantStyle in $metadata.GetElementsByTagName('variant-style')) {
        foreach ($variant in ($variantStyle.InnerText -split ',')) {
            $normalizedVariant = $variant.Trim()
            if (-not [string]::IsNullOrWhiteSpace($normalizedVariant)) {
                $variants[$normalizedVariant] = $true
            }
        }
    }

    return @($variants.Keys)
}

function Get-VariantOutputPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$VariantStyle
    )

    if ([string]::IsNullOrWhiteSpace($VariantStyle)) {
        return $Path
    }

    $directory = Split-Path -Parent $Path
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [System.IO.Path]::GetExtension($Path)
    $variantToken = [regex]::Replace($VariantStyle.ToLowerInvariant(), '[^a-z0-9._-]+', '-')

    return Join-Path $directory "$fileName-$variantToken$extension"
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

function Get-ElementDepth {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Element)

    $depth = 0
    $parent = $Element.ParentNode
    while ($null -ne $parent -and $parent.NodeType -eq [System.Xml.XmlNodeType]::Element) {
        $depth++
        $parent = $parent.ParentNode
    }

    return $depth
}

function Format-StyleElement {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Style)

    $depth = Get-ElementDepth -Element $Style
    $contentIndent = ' ' * (($depth + 1) * 2)
    $closingIndent = ' ' * ($depth * 2)
    $lines = $Style.InnerText.Trim() -split '\r?\n'
    $cssDepth = 0

    $formattedLines = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            ''
        } else {
            $cssLine = $line.Trim()
            if ($cssLine.StartsWith('}')) {
                $cssDepth = [Math]::Max(0, $cssDepth - 1)
            }

            $formattedLine = $contentIndent + (' ' * ($cssDepth * 2)) + $cssLine
            if ($cssLine.EndsWith('{')) {
                $cssDepth++
            }

            $formattedLine
        }
    }

    $Style.InnerText = "`n" + ($formattedLines -join "`n") + "`n" + $closingIndent
}

function Format-StyleElements {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)

    foreach ($element in $Document.GetElementsByTagName('*')) {
        if ($element.LocalName -eq 'style') {
            Format-StyleElement -Style $element
        }
    }
}

function Get-CssCustomProperties {
    param([AllowEmptyString()][string]$Text)

    $properties = [ordered]@{}
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $properties
    }

    foreach ($match in [regex]::Matches($Text, '--(?<name>[A-Za-z0-9_-]+)\s*:\s*(?<value>[^;]+);')) {
        $properties[$match.Groups['name'].Value] = $match.Groups['value'].Value.Trim()
    }

    return $properties
}

function Set-SvgCustomProperties {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Svg,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Properties
    )

    if ($Properties.Count -eq 0) {
        return
    }

    $style = Get-DirectChildElement -Parent $Svg -LocalName 'style'
    if ($null -eq $style) {
        $style = $Svg.OwnerDocument.CreateElement('style', $Svg.NamespaceURI)
        $style.InnerText = ":root {`n}`n"
        [void]$Svg.InsertBefore($style, $Svg.FirstChild)
    }

    foreach ($property in $Properties.GetEnumerator()) {
        $name = [regex]::Escape($property.Key)
        $value = $property.Value
        $pattern = "(?<prefix>--$name\s*:\s*)[^;]+;"

        if ([regex]::IsMatch($style.InnerText, $pattern)) {
            $style.InnerText = [regex]::Replace($style.InnerText, $pattern, {
                param($match)

                return $match.Groups['prefix'].Value + $value + ';'
            })
        } elseif ([regex]::IsMatch($style.InnerText, ':root\s*\{')) {
            $style.InnerText = [regex]::Replace($style.InnerText, ':root\s*\{', {
                param($match)

                return $match.Value + "`n  --$($property.Key): $value;"
            }, 1)
        } else {
            $style.InnerText += "`n:root {`n  --$($property.Key): $value;`n}`n"
        }
    }
}

function Get-ElementClassNames {
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Element)

    if (-not $Element.HasAttribute('class')) {
        return @()
    }

    return @($Element.GetAttribute('class') -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Add-ElementClassName {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory)][string]$ClassName
    )

    $classNames = @(Get-ElementClassNames -Element $Element)
    if ($classNames -notcontains $ClassName) {
        $classNames += $ClassName
        $Element.SetAttribute('class', ($classNames -join ' '))
    }
}

function Remove-ElementClassName {
    param(
        [Parameter(Mandatory)][System.Xml.XmlElement]$Element,
        [Parameter(Mandatory)][string]$ClassName
    )

    $classNames = @(Get-ElementClassNames -Element $Element | Where-Object { $_ -ne $ClassName })
    if ($classNames.Count -eq 0) {
        [void]$Element.RemoveAttribute('class')
    } else {
        $Element.SetAttribute('class', ($classNames -join ' '))
    }
}

function Test-CssSelectorAppliesToRoot {
    param(
        [Parameter(Mandatory)][string]$Selector,
        [Parameter(Mandatory)][System.Xml.XmlElement]$Root
    )

    $selector = $Selector.Trim()
    if ($selector -eq ':root' -or $selector -eq 'svg') {
        return $true
    }

    $classMatch = [regex]::Match($selector, '^(?:svg)?\.(?<class>[A-Za-z0-9_-]+)$')
    if ($classMatch.Success) {
        return @(Get-ElementClassNames -Element $Root) -contains $classMatch.Groups['class'].Value
    }

    return $false
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
        $customProperties = Get-CssCustomProperties -Text $image.GetAttribute('style')
        Set-SvgCustomProperties -Svg $assetSvg -Properties $customProperties
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

function Resolve-CssValue {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][hashtable]$Variables,
        [Parameter(Mandatory)][hashtable]$Seen
    )

    return [regex]::Replace($Value, 'var\(--(?<name>[A-Za-z0-9_-]+)\)', {
        param($match)

        $name = $match.Groups['name'].Value
        if (-not $Variables.ContainsKey($name) -or $Seen.ContainsKey($name)) {
            return $match.Value
        }

        $nestedSeen = $Seen.Clone()
        $nestedSeen[$name] = $true
        return Resolve-CssValue -Value $Variables[$name] -Variables $Variables -Seen $nestedSeen
    })
}

function Resolve-CssVariables {
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Document)

    $variables = @{}
    $elements = @($Document.GetElementsByTagName('*'))

    foreach ($element in $elements) {
        if ($element.LocalName -ne 'style') {
            continue
        }

        foreach ($block in [regex]::Matches($element.InnerText, '(?s)(?<selector>[^{}]+)\{(?<body>[^{}]*)\}')) {
            $selectors = $block.Groups['selector'].Value -split ','
            $applies = $false

            foreach ($selector in $selectors) {
                if (Test-CssSelectorAppliesToRoot -Selector $selector -Root $Document.DocumentElement) {
                    $applies = $true
                    break
                }
            }

            if (-not $applies) {
                continue
            }

            foreach ($property in (Get-CssCustomProperties -Text $block.Groups['body'].Value).GetEnumerator()) {
                $variables[$property.Key] = $property.Value
            }
        }
    }

    if ($variables.Count -eq 0) {
        return
    }

    foreach ($name in @($variables.Keys)) {
        $seen = @{}
        $seen[$name] = $true
        $variables[$name] = Resolve-CssValue -Value $variables[$name] -Variables $variables -Seen $seen
    }

    foreach ($element in $elements) {
        foreach ($attribute in @($element.Attributes)) {
            $attribute.Value = [regex]::Replace($attribute.Value, 'var\(--(?<name>[A-Za-z0-9_-]+)\)', {
                param($match)

                $name = $match.Groups['name'].Value
                if ($variables.ContainsKey($name)) {
                    return $variables[$name]
                }

                return $match.Value
            })

            if ($attribute.Name -eq 'style') {
                $attribute.Value = [regex]::Replace($attribute.Value, '--[A-Za-z0-9_-]+\s*:\s*[^;]+;\s*', '').Trim()
                if ([string]::IsNullOrWhiteSpace($attribute.Value)) {
                    [void]$element.Attributes.Remove($attribute)
                }
            }
        }

        if ($element.LocalName -eq 'style') {
            $element.InnerText = [regex]::Replace($element.InnerText, 'var\(--(?<name>[A-Za-z0-9_-]+)\)', {
                param($match)

                $name = $match.Groups['name'].Value
                if ($variables.ContainsKey($name)) {
                    return $variables[$name]
                }

                return $match.Value
            })

            $element.InnerText = [regex]::Replace($element.InnerText, '--[A-Za-z0-9_-]+\s*:\s*[^;]+;\s*', '')
            $element.InnerText = [regex]::Replace($element.InnerText, '(?s)[^{}]+\{\s*\}', '')

            $styleText = $element.InnerText.Trim()
            if ([string]::IsNullOrWhiteSpace($styleText)) {
                [void]$element.ParentNode.RemoveChild($element)
            }
        }
    }
}

function Convert-SvgToPng {
    param(
        [Parameter(Mandatory)][string]$SvgPath,
        [Parameter(Mandatory)][string]$PngPath
    )

    $magickCommand = Get-Command 'magick' -ErrorAction SilentlyContinue
    if ($null -eq $magickCommand) {
        throw "ImageMagick 'magick' command is required to generate PNG output."
    }

    & $magickCommand.Source $SvgPath $PngPath
    if ($LASTEXITCODE -ne 0) {
        throw "ImageMagick failed to generate PNG output: $PngPath"
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

    $extraFormats = Get-ExtraFormats -Document $document
    $variantStyles = @(Get-VariantStyles -Document $document)
    if ($variantStyles.Count -eq 0) {
        $variantStyles = @('')
    }

    $relativePath = [System.IO.Path]::GetRelativePath($sourceRootPath, $sourceFile.FullName)
    $outputPath = Join-Path $outputRootPath $relativePath
    $outputDirectory = Split-Path -Parent $outputPath

    if (-not (Test-Path -LiteralPath $outputDirectory)) {
        [void](New-Item -ItemType Directory -Path $outputDirectory -Force)
    }

    foreach ($variantStyle in $variantStyles) {
        $outputDocument = [System.Xml.XmlDocument]$document.Clone()
        $variantOutputPath = Get-VariantOutputPath -Path $outputPath -VariantStyle $variantStyle

        if (-not [string]::IsNullOrWhiteSpace($variantStyle)) {
            Add-ElementClassName -Element $outputDocument.DocumentElement -ClassName $variantStyle
        }

        Inline-ExternalPaintServers -Document $outputDocument -SourcePath $sourceFile.FullName
        Inline-Stylesheets -Document $outputDocument -SourcePath $sourceFile.FullName
        Inline-SvgImages -Document $outputDocument -SourcePath $sourceFile.FullName
        Resolve-CssVariables -Document $outputDocument

        if (-not [string]::IsNullOrWhiteSpace($variantStyle)) {
            Remove-ElementClassName -Element $outputDocument.DocumentElement -ClassName $variantStyle
        }

        Format-StyleElements -Document $outputDocument
        Save-XmlDocument -Document $outputDocument -Path $variantOutputPath
        $generated += $variantOutputPath

        foreach ($format in $extraFormats) {
            switch ($format) {
                'PNG' {
                    $pngPath = [System.IO.Path]::ChangeExtension($variantOutputPath, '.png')
                    Convert-SvgToPng -SvgPath $variantOutputPath -PngPath $pngPath
                    $generated += $pngPath
                }
                default {
                    Write-Warning "Unsupported extra format '$format' in $($sourceFile.FullName)"
                }
            }
        }
    }
}

if ($generated.Count -eq 0) {
    Write-Host 'No SVG files opted in with <metadata><output>true</output></metadata>.'
} else {
    Write-Host "Generated $($generated.Count) image file(s):"
    foreach ($path in $generated) {
        Write-Host "  $path"
    }
}
