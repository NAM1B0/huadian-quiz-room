$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$bitmap = [System.Drawing.Bitmap]::new(1024, 1024)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([System.Drawing.Color]::FromArgb(23, 58, 99))
$pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 70)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$graphics.DrawLine($pen, 265, 255, 225, 760)
$graphics.DrawLine($pen, 745, 255, 705, 760)
$graphics.DrawLine($pen, 248, 510, 724, 510)
$points = [System.Drawing.Point[]]@([System.Drawing.Point]::new(574, 228), [System.Drawing.Point]::new(393, 557), [System.Drawing.Point]::new(504, 557), [System.Drawing.Point]::new(452, 799), [System.Drawing.Point]::new(652, 461), [System.Drawing.Point]::new(539, 461))
$brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(104, 217, 212))
$graphics.FillPolygon($brush, $points)
$destination = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Assets.xcassets/AppIcon.appiconset/AppIcon.png'))
$bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
$brush.Dispose()
$pen.Dispose()
$graphics.Dispose()
$bitmap.Dispose()
Write-Output $destination
