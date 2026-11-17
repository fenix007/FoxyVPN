param([string]$SourcePath)

$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $RepositoryRoot 'assets/branding/foxy-superhero.png'
}
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "Save the square GPT Image artwork to $SourcePath before preparing app icons."
}
Add-Type -AssemblyName System.Drawing

function New-ScaledBitmap([System.Drawing.Image]$Image, [int]$Size, [bool]$AdaptiveForeground) {
    $Bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    try {
        $Graphics.Clear([System.Drawing.Color]::Transparent)
        $Graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $Graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $ArtworkSize = if ($AdaptiveForeground) { [int]($Size * 72 / 108) } else { $Size }
        $Inset = [int](($Size - $ArtworkSize) / 2)
        $Destination = New-Object System.Drawing.Rectangle($Inset, $Inset, $ArtworkSize, $ArtworkSize)
        $Attributes = New-Object System.Drawing.Imaging.ImageAttributes
        try {
            $Attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
            $Graphics.DrawImage($Image, $Destination, 0, 0, $Image.Width, $Image.Height,
                [System.Drawing.GraphicsUnit]::Pixel, $Attributes)
        } finally { $Attributes.Dispose() }
    } finally { $Graphics.Dispose() }
    return $Bitmap
}

function New-DesktopBitmap([System.Drawing.Image]$Image) {
    # Supersampling gives the transparent rounded outline a smooth alpha edge.
    $Scale = 4
    $Canvas = 1024 * $Scale
    $Inset = 64 * $Scale
    $Tile = 896 * $Scale
    $Diameter = 360 * $Scale
    $Large = New-Object System.Drawing.Bitmap($Canvas, $Canvas, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $Graphics = [System.Drawing.Graphics]::FromImage($Large)
    $Outline = New-Object System.Drawing.Drawing2D.GraphicsPath
    $Attributes = New-Object System.Drawing.Imaging.ImageAttributes
    try {
        $Graphics.Clear([System.Drawing.Color]::Transparent)
        $Graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $Graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $Far = $Inset + $Tile - $Diameter
        $Outline.AddArc($Inset, $Inset, $Diameter, $Diameter, 180, 90)
        $Outline.AddArc($Far, $Inset, $Diameter, $Diameter, 270, 90)
        $Outline.AddArc($Far, $Far, $Diameter, $Diameter, 0, 90)
        $Outline.AddArc($Inset, $Far, $Diameter, $Diameter, 90, 90)
        $Outline.CloseFigure()
        $Graphics.SetClip($Outline)
        $Attributes.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $Destination = New-Object System.Drawing.Rectangle($Inset, $Inset, $Tile, $Tile)
        $Graphics.DrawImage($Image, $Destination, 0, 0, $Image.Width, $Image.Height,
            [System.Drawing.GraphicsUnit]::Pixel, $Attributes)
        $Desktop = New-ScaledBitmap $Large 1024 $false
        $FinalGraphics = [System.Drawing.Graphics]::FromImage($Desktop)
        try {
            # Resampling can bleed fractional alpha one pixel beyond the tile's
            # bounding box. Keep the 64 px exterior margin fully transparent.
            $FinalGraphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $FinalGraphics.FillRectangle([System.Drawing.Brushes]::Transparent, 0, 0, 1024, 64)
            $FinalGraphics.FillRectangle([System.Drawing.Brushes]::Transparent, 0, 960, 1024, 64)
            $FinalGraphics.FillRectangle([System.Drawing.Brushes]::Transparent, 0, 64, 64, 896)
            $FinalGraphics.FillRectangle([System.Drawing.Brushes]::Transparent, 960, 64, 64, 896)
        } finally { $FinalGraphics.Dispose() }
        return $Desktop
    } finally {
        $Attributes.Dispose()
        $Outline.Dispose()
        $Graphics.Dispose()
        $Large.Dispose()
    }
}

function New-AdaptiveBackground([System.Drawing.Bitmap]$Image, [int]$Size) {
    $ArtworkSize = [int]($Size * 72 / 108)
    $Inset = [int](($Size - $ArtworkSize) / 2)
    $Artwork = New-ScaledBitmap $Image $ArtworkSize $false
    $Bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
    try {
        $Graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $Graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        # Copy the complete scaled artwork in the central 72 dp. Fill the 18 dp
        # sides by extending its outermost pixels; parallax then reveals only
        # matching background colour instead of a rectangular transparent edge.
        foreach ($Column in 0..2) {
            foreach ($Row in 0..2) {
                $SourceX = if ($Column -eq 2) { $ArtworkSize - 1 } else { 0 }
                $SourceY = if ($Row -eq 2) { $ArtworkSize - 1 } else { 0 }
                $SourceWidth = if ($Column -eq 1) { $ArtworkSize } else { 1 }
                $SourceHeight = if ($Row -eq 1) { $ArtworkSize } else { 1 }
                $TargetX = if ($Column -eq 0) { 0 } elseif ($Column -eq 1) { $Inset } else { $Inset + $ArtworkSize }
                $TargetY = if ($Row -eq 0) { 0 } elseif ($Row -eq 1) { $Inset } else { $Inset + $ArtworkSize }
                $TargetWidth = if ($Column -eq 1) { $ArtworkSize } else { $Inset }
                $TargetHeight = if ($Row -eq 1) { $ArtworkSize } else { $Inset }
                $CropRectangle = New-Object System.Drawing.Rectangle($SourceX, $SourceY, $SourceWidth, $SourceHeight)
                $Crop = $Artwork.Clone($CropRectangle, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
                try {
                    $TargetRectangle = New-Object System.Drawing.Rectangle($TargetX, $TargetY, $TargetWidth, $TargetHeight)
                    $Graphics.DrawImage($Crop, $TargetRectangle, 0, 0, $Crop.Width, $Crop.Height, [System.Drawing.GraphicsUnit]::Pixel)
                } finally { $Crop.Dispose() }
            }
        }
    } finally { $Graphics.Dispose(); $Artwork.Dispose() }
    return $Bitmap
}

$Image = [System.Drawing.Bitmap]::FromFile((Resolve-Path -LiteralPath $SourcePath).Path)
$Desktop = $null
try {
    if ($Image.Width -ne $Image.Height -or $Image.Width -lt 512) {
        throw 'The source icon must be square and at least 512 by 512 pixels (1024 recommended).'
    }
    $Desktop = New-DesktopBitmap $Image
    $DesktopPath = Join-Path $RepositoryRoot 'assets/branding/foxy-superhero-desktop.png'
    $Desktop.Save($DesktopPath, [System.Drawing.Imaging.ImageFormat]::Png)

    # PNG-compressed frames preserve alpha and are supported by the target Windows versions.
    $Sizes = @(16, 24, 32, 48, 64, 128, 256)
    $Frames = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($Size in $Sizes) {
        $Bitmap = New-ScaledBitmap $Desktop $Size $false
        $Stream = New-Object System.IO.MemoryStream
        try {
            $Bitmap.Save($Stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $Frames.Add($Stream.ToArray())
        } finally { $Stream.Dispose(); $Bitmap.Dispose() }
    }
    $IconDirectory = Join-Path $RepositoryRoot 'windows/FoxyVPN/Assets'
    [System.IO.Directory]::CreateDirectory($IconDirectory) | Out-Null
    $IconPath = Join-Path $IconDirectory 'FoxyVPN.ico'
    $IconStream = [System.IO.File]::Create($IconPath)
    $Writer = New-Object System.IO.BinaryWriter($IconStream)
    try {
        $Writer.Write([uint16]0)
        $Writer.Write([uint16]1)
        $Writer.Write([uint16]$Sizes.Count)
        $Offset = 6 + 16 * $Sizes.Count
        for ($Index = 0; $Index -lt $Sizes.Count; $Index++) {
            $Dimension = if ($Sizes[$Index] -eq 256) { 0 } else { $Sizes[$Index] }
            $Writer.Write([byte]$Dimension)
            $Writer.Write([byte]$Dimension)
            $Writer.Write([byte]0)
            $Writer.Write([byte]0)
            $Writer.Write([uint16]1)
            $Writer.Write([uint16]32)
            $Writer.Write([uint32]$Frames[$Index].Length)
            $Writer.Write([uint32]$Offset)
            $Offset += $Frames[$Index].Length
        }
        foreach ($Frame in $Frames) { $Writer.Write([byte[]]$Frame) }
    } finally { $Writer.Dispose(); $IconStream.Dispose() }

    # The existing vector foreground/background remain available in drawable/.
    $Densities = [ordered]@{ mdpi = 108; hdpi = 162; xhdpi = 216; xxhdpi = 324; xxxhdpi = 432 }
    foreach ($Entry in $Densities.GetEnumerator()) {
        $ResourceDirectory = Join-Path $RepositoryRoot "app/src/main/res/drawable-$($Entry.Key)"
        [System.IO.Directory]::CreateDirectory($ResourceDirectory) | Out-Null
        $Bitmap = New-AdaptiveBackground $Image $Entry.Value
        try {
            $Bitmap.Save((Join-Path $ResourceDirectory 'ic_launcher_superhero.png'), [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $Bitmap.Dispose() }
    }
    Write-Output "Prepared $DesktopPath, $IconPath and Android adaptive icon images."
} finally {
    if ($null -ne $Desktop) { $Desktop.Dispose() }
    $Image.Dispose()
}
