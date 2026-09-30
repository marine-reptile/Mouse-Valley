# maptool.ps1 - generator for MouseLivingRoom.tmx and the two family houses (PowerShell port of the C# maptool)
#   gen    <srcTmx> <dstTmx> [checklist "Name,x,y;..."]
#   house  <Felix|Kerwin> <dstTmx>
#   render <tmx> <out.png> <scale> [grid|nogrid] [x y w h]
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Xml.Linq
Add-Type -AssemblyName System.Drawing

$script:Vanilla = 'D:\Jucason\Stardew-Valley-Developer\Content (unpacked)\Maps'
$script:TI = 5071; $script:T2 = 7247
$script:MapW = 40; $script:MapH = 30
# tilesets Stamp may copy into the target map, by image name
$script:SetFirst = @{ townInterior = 5071; townInterior_2 = 7247 }
$script:GL = [ordered]@{}
$script:Cache = @{}
# townInterior edge and corner pieces that stamps must not copy from vanilla rooms
$script:Structural = @(0, 1, 2, 3, 32, 36, 41, 43, 56, 64, 68, 88, 160, 161, 162, 163, 164, 165, 166, 167, 193, 194, 2120, 2121, 2152, 2153, 2112, 2144, 2145, 2146)

function Full([string]$P) { [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $P)) }

# ---------------------------------------------------------------- tmx reading

function Load-Tmx([string]$Path) {
    $full = Full $Path
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($full)
    $m = $doc.DocumentElement
    $sets = @()
    foreach ($t in $m.SelectNodes('tileset')) {
        $sets += [pscustomobject]@{
            First = [int]$t.GetAttribute('firstgid'); Cols = [int]$t.GetAttribute('columns')
            Source = $t.SelectSingleNode('image').GetAttribute('source'); Img = $null
        }
    }
    $layers = [ordered]@{}
    foreach ($l in $m.SelectNodes('layer')) {
        $parts = @($l.SelectSingleNode('data').InnerText -split '[,\s]+' | Where-Object { $_ -ne '' })
        $d = New-Object int[] $parts.Count
        for ($i = 0; $i -lt $parts.Count; $i++) { $d[$i] = [int]([uint64]$parts[$i] -band 0x0FFFFFFF) }
        $layers[$l.GetAttribute('name')] = $d
    }
    [pscustomobject]@{
        W = [int]$m.GetAttribute('width'); H = [int]$m.GetAttribute('height')
        Sets = @($sets | Sort-Object First -Descending); Layers = $layers; Dir = [IO.Path]::GetDirectoryName($full)
    }
}

function Find-Set($M, [int]$Gid) { foreach ($t in $M.Sets) { if ($t.First -le $Gid) { return $t } }; $null }

# ---------------------------------------------------------------- tile editing

function Lay([string]$Name) {
    if (-not $script:GL.Contains($Name)) { $script:GL[$Name] = New-Object int[] ($script:MapW * $script:MapH) }
    return , $script:GL[$Name]
}

function SetT([string]$Ln, [int]$X, [int]$Y, [int]$Id, [int]$Set = $script:TI) {
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $script:MapW -or $Y -ge $script:MapH) { return }
    $a = Lay $Ln
    if ($Id -lt 0) { $a[$Y * $script:MapW + $X] = 0 } else { $a[$Y * $script:MapW + $X] = $Set + $Id }
}

function ClearT([string]$Ln, [int]$X, [int]$Y) {
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $script:MapW -or $Y -ge $script:MapH) { return }
    $a = Lay $Ln
    $a[$Y * $script:MapW + $X] = 0
}

# copy a vanilla rect; layers: all but Paths; Back only with -WithBack
function Stamp([string]$Map, [int]$Sx, [int]$Sy, [int]$Sw, [int]$Sh, [int]$Dx, [int]$Dy, [switch]$WithBack, [string]$Skip = '') {
    if (-not $script:Cache.ContainsKey($Map)) { $script:Cache[$Map] = Load-Tmx (Join-Path $script:Vanilla "$Map.tmx") }
    $m = $script:Cache[$Map]
    $skips = @($Skip -split ',' | Where-Object { $_ })
    foreach ($ln in @($m.Layers.Keys)) {
        if ($ln -eq 'Paths' -or ($ln -eq 'Back' -and -not $WithBack) -or $skips -contains $ln) { continue }
        $d = $m.Layers[$ln]
        for ($yy = 0; $yy -lt $Sh; $yy++) {
            for ($xx = 0; $xx -lt $Sw; $xx++) {
                $g = $d[($Sy + $yy) * $m.W + $Sx + $xx]
                if ($g -eq 0) { continue }
                $ts = Find-Set $m $g
                $n = [IO.Path]::GetFileNameWithoutExtension($ts.Source.TrimStart('.'))
                if ($script:SetFirst.ContainsKey($n)) { $f = $script:SetFirst[$n] } else { $f = -1 }
                if ($f -lt 0) { [Console]::Error.WriteLine("skip $n in $Map"); continue }
                $id = $g - $ts.First
                if ($f -eq $script:TI -and $script:Structural -contains $id) { continue }
                SetT $ln ($Dx + $xx) ($Dy + $yy) $id $f
            }
        }
    }
}

# ---------------------------------------------------------------- tmx writing

function Save-Tmx([string]$Src, [string]$Dst) {
    $doc = [System.Xml.Linq.XDocument]::Load((Full $Src))
    $root = $doc.Root
    $nextId = [int]$root.Attribute('nextlayerid').Value
    $w = $script:MapW; $h = $script:MapH
    foreach ($k in @($script:GL.Keys)) {
        $v = $script:GL[$k]
        $le = $null
        foreach ($e in $root.Elements('layer')) { if ($e.Attribute('name').Value -eq $k) { $le = $e; break } }
        if ($null -eq $le) {
            if (-not ($v | Where-Object { $_ -ne 0 } | Select-Object -First 1)) { continue }
            $le = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]'layer')
            $le.SetAttributeValue('id', $nextId); $nextId++
            $le.SetAttributeValue('name', $k); $le.SetAttributeValue('width', $w); $le.SetAttributeValue('height', $h)
            $data = [System.Xml.Linq.XElement]::new([System.Xml.Linq.XName]'data')
            $data.SetAttributeValue('encoding', 'csv')
            $le.Add($data)
            # insert after the last layer of the same family (Back2 after Back, Front2 after Front)
            $base = $k -replace '[^A-Za-z].*$', ''
            $after = $null
            foreach ($e in $root.Elements('layer')) { if ($e.Attribute('name').Value.StartsWith($base)) { $after = $e } }
            $after.AddAfterSelf($le)
        }
        $rows = for ($y = 0; $y -lt $h; $y++) { ($v[($y * $w)..($y * $w + $w - 1)]) -join ',' }
        $le.Element('data').Value = "`n" + ($rows -join ",`n") + "`n"
    }
    # tile layers this run did not touch are cleared, so the repo map itself can be the source (Paths is kept)
    $zero = (@('0') * $w) -join ','
    foreach ($e in $root.Elements('layer')) {
        $n = $e.Attribute('name').Value
        if ($n -eq 'Paths' -or $script:GL.Contains($n)) { continue }
        $e.Element('data').Value = "`n" + ((@($zero) * $h) -join ",`n") + "`n"
    }
    $root.SetAttributeValue('nextlayerid', $nextId)
    $set = New-Object System.Xml.XmlWriterSettings
    $set.Indent = $true; $set.IndentChars = ' '; $set.NewLineChars = "`r`n"; $set.Encoding = New-Object System.Text.UTF8Encoding($false)
    $xw = [System.Xml.XmlWriter]::Create((Full $Dst), $set)
    try { $doc.Save($xw) } finally { $xw.Close() }
}

function Check([string]$List) {
    $b = Lay 'Buildings'; $bk = Lay 'Back'
    foreach ($p in $List -split ';') {
        $v = $p -split ','; $x = [int]$v[1]; $y = [int]$v[2]; $i = $y * $script:MapW + $x
        $g = $b[$i]
        if ($g -eq 0 -and $bk[$i] -ne 0) { $s = 'ok' } else { $s = "BLOCKED $($g - $script:TI)" }
        '{0,-8} {1},{2} {3}' -f $v[0], $x, $y, $s
    }
}

# ---------------------------------------------------------------- rendering

function Resolve-Img([string]$Dir, [string]$Src) {
    $n = [IO.Path]::GetFileName($Src); if (-not $n.EndsWith('.png')) { $n += '.png' }
    $local = Join-Path $Dir $n
    if (-not $n.StartsWith('.') -and (Test-Path -LiteralPath $local)) { return $local }
    $v = Join-Path $script:Vanilla $n.TrimStart('.'); if (Test-Path -LiteralPath $v) { return $v }
    $l2 = Join-Path $Dir $n.TrimStart('.'); if (Test-Path -LiteralPath $l2) { return $l2 }
    $null
}

function Render([string]$Tmx, [string]$Out, [int]$Scale, [bool]$Grid, [int]$X0 = 0, [int]$Y0 = 0, [int]$RW = 0, [int]$RH = 0) {
    $m = Load-Tmx $Tmx
    if ($RW -le 0) { $RW = $m.W - $X0 }; if ($RH -le 0) { $RH = $m.H - $Y0 }
    foreach ($ts in $m.Sets) {
        $p = Resolve-Img $m.Dir $ts.Source
        if ($p) { $ts.Img = [System.Drawing.Image]::FromFile($p) } else { [Console]::Error.WriteLine("missing tileset $($ts.Source)") }
    }
    $t = 16 * $Scale
    $bmp = New-Object System.Drawing.Bitmap ($RW * $t), ($RH * $t)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $g.Clear([System.Drawing.Color]::Black)
    foreach ($ln in @($m.Layers.Keys)) {
        if ($ln -eq 'Paths') { continue }
        $d = $m.Layers[$ln]
        for ($y = $Y0; $y -lt [Math]::Min($m.H, $Y0 + $RH); $y++) {
            for ($x = $X0; $x -lt [Math]::Min($m.W, $X0 + $RW); $x++) {
                $gid = $d[$y * $m.W + $x]
                if ($gid -eq 0) { continue }
                $ts = Find-Set $m $gid
                if ($null -eq $ts -or $null -eq $ts.Img) { continue }
                $id = $gid - $ts.First
                $sx = ($id % $ts.Cols) * 16; $sy = [int][Math]::Floor($id / $ts.Cols) * 16
                if ($sx + 16 -gt $ts.Img.Width -or $sy + 16 -gt $ts.Img.Height) { continue }
                $g.DrawImage($ts.Img, [System.Drawing.Rectangle]::new(($x - $X0) * $t, ($y - $Y0) * $t, $t, $t),
                    [System.Drawing.Rectangle]::new($sx, $sy, 16, 16), [System.Drawing.GraphicsUnit]::Pixel)
            }
        }
    }
    if ($Grid) {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(70, 255, 255, 255))
        $font = New-Object System.Drawing.Font 'Consolas', (2.6 * $Scale), ([System.Drawing.GraphicsUnit]::Pixel)
        $bg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(170, 0, 0, 0))
        for ($y = $Y0; $y -lt [Math]::Min($m.H, $Y0 + $RH); $y++) {
            for ($x = $X0; $x -lt [Math]::Min($m.W, $X0 + $RW); $x++) {
                $g.DrawRectangle($pen, ($x - $X0) * $t, ($y - $Y0) * $t, $t, $t)
                $s = "$x,$y"; $sz = $g.MeasureString($s, $font)
                $g.FillRectangle($bg, [single](($x - $X0) * $t), [single](($y - $Y0) * $t), $sz.Width, $sz.Height)
                $g.DrawString($s, $font, [System.Drawing.Brushes]::Yellow, [single](($x - $X0) * $t), [single](($y - $Y0) * $t))
            }
        }
    }
    $g.Dispose()
    $bmp.Save((Full $Out), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    foreach ($ts in $m.Sets) { if ($ts.Img) { $ts.Img.Dispose() } }
}

# ---------------------------------------------------------------- living room layout

$LB = 'Back'; $LU = 'Buildings'; $LF = 'Front'
$WALL = 505; $WAIN = 112; $AISLE = 170

function Floor([int]$X, [int]$Y, [switch]$Top) {
    if (($X -ge 22 -and $X -le 23) -or ($Y -ge 16 -and $Y -le 17)) { SetT $LB $X $Y $AISLE; return }
    if ($Top) { if ($X % 2 -eq 0) { SetT $LB $X $Y 199 } else { SetT $LB $X $Y 200 } }
    elseif ($Y % 2 -eq 0) { SetT $LB $X $Y (231 + $X % 2) }
    else { SetT $LB $X $Y (263 + $X % 2) }
}

function Black([int]$X, [int]$Y) { SetT $LU $X $Y 0 }

# horizontal wall: border row Bo, wall rows Bo+1..Bo+3
# ends: "corner" = room corner trim, "cap" = wall ends at an opening, "open" = runs off the map
function Wall([int]$Xa, [int]$Xb, [int]$Bo, [string]$Left, [string]$Right) {
    for ($x = $Xa; $x -le $Xb; $x++) {
        SetT $LF $x $Bo 2; Black $x $Bo
        SetT $LB $x ($Bo + 1) $WALL; SetT $LB $x ($Bo + 2) $WALL; SetT $LB $x ($Bo + 3) $WAIN
        SetT $LU $x ($Bo + 2) 80; SetT $LU $x ($Bo + 3) 112
    }
    if ($Left -eq 'corner') { SetT $LU $Xa ($Bo + 2) 79; SetT $LU $Xa ($Bo + 3) 111; SetT $LU $Xa ($Bo + 4) 143 }
    if ($Left -eq 'cap') { SetT $LU $Xa ($Bo + 1) 154; SetT $LU $Xa ($Bo + 2) 186; SetT $LU $Xa ($Bo + 3) 218 }
    if ($Right -eq 'corner') { SetT $LU $Xb ($Bo + 2) 81; SetT $LU $Xb ($Bo + 3) 113; SetT $LU $Xb ($Bo + 4) 145 }
    if ($Right -eq 'cap') { SetT $LU $Xb ($Bo + 1) 155; SetT $LU $Xb ($Bo + 2) 187; SetT $LU $Xb ($Bo + 3) 219 }
}

# stretch a 3-column source horizontally: left col, middle col repeated N times, right col
function Stretch([string]$Map, [int]$Sx, [int]$Sy, [int]$Sh, [int]$N, [int]$Dx, [int]$Dy) {
    Stamp $Map $Sx $Sy 1 $Sh $Dx $Dy
    for ($i = 0; $i -lt $N; $i++) { Stamp $Map ($Sx + 1) $Sy 1 $Sh ($Dx + 1 + $i) $Dy }
    Stamp $Map ($Sx + 2) $Sy 1 $Sh ($Dx + 1 + $N) $Dy
}

function Rug([int]$X0, [int]$Y0, [int]$N) {
    for ($i = 0; $i -lt $N + 2; $i++) {
        if ($i -eq 0) { $c = 0 } elseif ($i -eq $N + 1) { $c = 2 } else { $c = 1 }
        SetT $LB ($X0 + $i) $Y0 (248 + $c); SetT $LB ($X0 + $i) ($Y0 + 1) (280 + $c)
    }
}

function Build {
    # floors
    for ($y = 9; $y -le 25; $y++) { for ($x = 5; $x -le 36; $x++) { Floor $x $y -Top:($y -eq 9) } }
    for ($y = 0; $y -le 8; $y++) { Floor 22 $y; Floor 23 $y }
    for ($y = 26; $y -le 29; $y++) { Floor 22 $y; Floor 23 $y }
    for ($x = 0; $x -le 4; $x++) { Floor $x 16; Floor $x 17 }
    for ($x = 37; $x -le 39; $x++) { Floor $x 16; Floor $x 17 }

    # top wall with the storeroom opening at 22-23
    Wall 5 21 5 'corner' 'cap'
    Wall 24 36 5 'cap' 'corner'
    for ($y = 6; $y -le 8; $y++) {
        if ($y -eq 8) { $id = $WAIN } else { $id = $WALL }
        SetT $LB 21 $y $id; SetT $LB 24 $y $id
    }
    # corridor up to the storeroom
    for ($y = 0; $y -le 4; $y++) { Black 21 $y; SetT $LF 21 $y 64; Black 24 $y; SetT $LF 24 $y 68 }
    SetT $LF 21 5 194; SetT $LF 24 5 193

    # room corners and side edges
    Black 4 5; SetT $LF 4 5 0; SetT $LF 5 5 1; Black 4 6; SetT $LF 4 6 32; SetT $LF 5 6 41
    Black 37 5; SetT $LF 37 5 0; SetT $LF 36 5 3; Black 37 6; SetT $LF 37 6 36; SetT $LF 36 6 43
    for ($y = 7; $y -le 11; $y++) { Black 4 $y; SetT $LF 4 $y 64; Black 37 $y; SetT $LF 37 $y 68 }
    for ($y = 18; $y -le 24; $y++) { Black 4 $y; SetT $LF 4 $y 64; Black 37 $y; SetT $LF 37 $y 68 }

    # left branch (Felix family)
    Wall 0 4 12 'open' 'cap'
    SetT $LF 4 12 194
    for ($x = 0; $x -le 3; $x++) { SetT $LF $x 17 165; Black $x 18 }
    SetT $LF 4 17 162
    # right branch (Kerwin family)
    Wall 37 39 12 'cap' 'open'
    SetT $LF 37 12 193
    for ($x = 38; $x -le 39; $x++) { SetT $LF $x 17 165; Black $x 18 }
    SetT $LF 37 17 163

    # bottom edge and the entrance
    for ($x = 5; $x -le 36; $x++) { if ($x -eq 22 -or $x -eq 23) { continue }; SetT $LF $x 25 165; Black $x 26 }
    Black 4 25; SetT $LF 4 25 160; SetT $LF 5 25 161
    Black 37 25; SetT $LF 37 25 167; SetT $LF 36 25 166
    SetT $LF 21 25 162; SetT $LF 24 25 163
    for ($y = 26; $y -le 29; $y++) { Black 21 $y; SetT $LF 21 $y 64; Black 24 $y; SetT $LF 24 $y 68 }

    Furnish
}

# stretch a source horizontally with explicit columns: left, middle columns cycled N times, right
function StretchCols([string]$Map, [int]$L, [int[]]$M, [int]$R, [int]$Sy, [int]$Sh, [int]$N, [int]$Dx, [int]$Dy) {
    Stamp $Map $L $Sy 1 $Sh $Dx $Dy
    for ($i = 0; $i -lt $N; $i++) { Stamp $Map $M[$i % $M.Count] $Sy 1 $Sh ($Dx + 1 + $i) $Dy }
    Stamp $Map $R $Sy 1 $Sh ($Dx + 1 + $N) $Dy
}

# chairs: north of a table edge at row Y (back above), south of a table edge at row Y (seat below)
function ChairN([int]$X, [int]$Y) { SetT $LF $X ($Y - 1) 489; SetT $LU $X $Y 521 }
function ChairS([int]$X, [int]$Y) { SetT $LF $X $Y 490; SetT $LU $X ($Y + 1) 522 }

# long dining table at X..X+N+1, rows Y..Y+2, end chairs, side chairs at the given column offsets
function Dining([int]$X, [int]$Y, [int]$N, [int[]]$Seats) {
    Stretch 'HaleyHouse' 19 17 3 $N $X $Y
    Stamp 'HaleyHouse' 18 18 1 2 ($X - 1) ($Y + 1)
    Stamp 'HaleyHouse' 22 18 1 2 ($X + $N + 2) ($Y + 1)
    foreach ($s in $Seats) { ChairN ($X + $s) $Y; ChairS ($X + $s) ($Y + 2) }
}

# study desk with a green lamp, 2x2
function Desk([int]$X, [int]$Y) { SetT $LF $X $Y 679; SetT $LF ($X + 1) $Y 777; SetT $LU $X ($Y + 1) 775; SetT $LU ($X + 1) ($Y + 1) 776 }

function Cushion([int]$X, [int]$Y) { SetT $LB $X $Y 508 }

function Furnish {
    $HH = 'HaleyHouse'; $AS = 'AnimalShop'; $AR = 'ArchaeologyHouse'; $SA = 'Saloon'
    # ---- top-left: reading hall around the fireplace
    StretchCols $AR 9 @(10, 11, 12) 13 1 4 6 6 6     # wall bookshelves 6-13
    Stamp $HH 13 11 2 5 15 5                         # brick fireplace
    SetT 'Buildings' 15 5 2; SetT 'Buildings' 16 5 2
    Stamp $HH 15 14 1 2 17 8                         # lamp table
    StretchCols $AR 15 @(16, 17) 21 1 4 1 18 6       # wall bookshelf 18-20
    SetT 'Front' 14 6 207
    for ($r = 0; $r -lt 4; $r++) {                   # 20 cushions, staggered, facing the lectern
        for ($c = 0; $c -lt 5; $c++) { Cushion (7 + $r % 2 + 2 * $c) (11 + $r) }
    }
    Stamp $AR 17 9 2 3 18 11                         # lectern with lamp
    Cushion 20 12                                    # reader's seat
    Stamp $HH 9 15 1 2 5 10                          # tall plant
    Stamp $HH 14 17 1 1 19 15                        # stool
    # ---- top-right: kitchen and the long feast table (12 seats)
    Stamp $HH 17 12 6 4 30 6                         # counters, stove, sink, fridge
    Stamp 'JoshHouse' 17 3 2 2 26 8                  # dresser
    Stamp $AS 4 15 1 2 25 8                          # barrel by the storeroom
    SetT 'Front' 28 6 207
    Dining 25 12 9 @(1, 3, 5, 7, 9)
    # ---- bottom-right: two family tables (6 seats each)
    Dining 25 20 2 @(1, 2)
    Dining 32 20 2 @(1, 2)
    Stamp $AS 4 15 1 2 30 22                         # barrel between the tables
    # ---- bottom-left: craft desk and seed store (Felix, Nina)
    Stamp $AS 11 13 4 3 5 18                         # work desk
    Stamp $AS 1 14 4 5 5 21 -WithBack                # barrels and hay on straw
    Stamp $AS 7 13 1 2 9 23                          # sacks
    # ---- bottom-middle: games (pool table, two arcade machines)
    Stamp $SA 37 19 5 3 10 19
    Stamp $SA 33 16 1 2 11 23
    Stamp $SA 35 16 1 2 13 23
    # ---- bottom: music and dance, study desks
    SetT 'Front' 19 19 664; SetT 'Front' 20 19 665   # jukebox
    SetT 'Buildings' 19 20 696; SetT 'Buildings' 20 20 697
    SetT 'Buildings' 19 21 728; SetT 'Buildings' 20 21 729
    Rug 15 19 2                                      # dance rug
    Desk 15 22; ChairN 15 22; ChairS 16 23
    Desk 18 22; ChairN 18 22; ChairS 19 23
    # ---- hints at the branches
    SetT 'Front' 2 13 175; SetT 'Front' 38 13 207
    # ---- plants marking the crossroads
    Stamp $HH 9 15 1 2 21 14
    Stamp $HH 9 15 1 2 24 18
}

# ---------------------------------------------------------------- family houses
# a house is a list of floor rects (rooms, corridors, doorways); walls, wall-end caps and the black
# border with its edge trims are derived from the floor mask, following FarmHouse and the living room.
# spacing rules: 4 rows between floors stacked vertically (border + 3 wall rows), 2 columns side by side

$script:HouseSets = @(
    @('townInterior', 1, 32, 512, 1088), @('townInterior_2', 2177, 32, 512, 656),
    @('walls_and_floors', 3489, 16, 256, 688), @('farmhouse_tiles', 4177, 12, 192, 352),
    @('CarolineGreenhouseTiles', 4441, 8, 128, 256))
$WF = 3489; $FH = 4177; $CG = 4441
$script:Rooms = @(); $script:Own = $null; $script:WK = $null; $script:WO = $null
$script:TileData = @(); $script:Props = [ordered]@{}

function House-Init([int]$W, [int]$H) {
    $script:MapW = $W; $script:MapH = $H; $script:TI = 1; $script:T2 = 2177
    $script:SetFirst = @{}; foreach ($s in $script:HouseSets) { $script:SetFirst[$s[0]] = $s[1] }
    $script:GL = [ordered]@{}; foreach ($n in 'Back', 'Buildings', 'Front', 'AlwaysFront') { $null = Lay $n }
    $script:Own = New-Object int[] ($W * $H); $script:Rooms = @(); $script:TileData = @(); $script:Props = [ordered]@{}
}

# floor style: tiles for [x even y even, x odd y even, x even y odd, x odd y odd]
function FloorWF([int]$B) { @{ S = $WF; T = @($B, ($B + 1), ($B + 16), ($B + 17)) } }
function FloorTI([int[]]$T) { if ($T.Count -eq 1) { $T = @($T[0]) * 4 }; @{ S = 1; T = $T } }
# wall style: Back tiles top/middle/bottom, Buildings tiles middle/bottom (-1 = none), Alt = alternate columns
function WallWF([int]$B) { @{ S = $WF; T = @($B, ($B + 16), ($B + 32)); B = @(-1, ($B + 32)); Alt = 0 } }
$GlassWall = @{ S = 1; T = @(1979, 2011, 2043); B = @(-1, 2043); Alt = 1 }

function Fill($R, [int]$X, [int]$Y, [int]$W, [int]$H) {
    for ($j = $Y; $j -lt $Y + $H; $j++) { for ($i = $X; $i -lt $X + $W; $i++) {
        if ($i -ge 0 -and $j -ge 0 -and $i -lt $script:MapW -and $j -lt $script:MapH) { $script:Own[$j * $script:MapW + $i] = $R.N }
    } }
}

function Room([string]$Id, [int]$X, [int]$Y, [int]$W, [int]$H, $Floor, $Wall) {
    $r = [pscustomobject]@{ Id = $Id; X = $X; Y = $Y; W = $W; H = $H; Floor = $Floor; Wall = $Wall; N = $script:Rooms.Count + 1 }
    $script:Rooms += $r
    Fill $r $X $Y $W $H
    $r
}

# doorway or corridor piece with the floor and wall style of an existing room
function Link($R, [int]$X, [int]$Y, [int]$W, [int]$H) { Fill $R $X $Y $W $H }

# floor / floor-or-wall tests; x is clamped so corridors running off the map edge stay open
function IsF([int]$X, [int]$Y) {
    if ($Y -lt 0 -or $Y -ge $script:MapH) { return $false }
    if ($X -lt 0) { $X = 0 } elseif ($X -ge $script:MapW) { $X = $script:MapW - 1 }
    $script:Own[$Y * $script:MapW + $X] -gt 0
}
function IsR([int]$X, [int]$Y) {
    if ($Y -lt 0 -or $Y -ge $script:MapH) { return $false }
    if ($X -lt 0) { $X = 0 } elseif ($X -ge $script:MapW) { $X = $script:MapW - 1 }
    $i = $Y * $script:MapW + $X
    $script:Own[$i] -gt 0 -or $script:WK[$i] -gt 0
}

function Autotile {
    $w = $script:MapW; $h = $script:MapH
    $script:WK = New-Object int[] ($w * $h); $script:WO = New-Object int[] ($w * $h)
    # walls: the 3 rows above every top edge of the floor (k = 1 bottom .. 3 top)
    for ($y = 0; $y -lt $h; $y++) { for ($x = 0; $x -lt $w; $x++) {
        $o = $script:Own[$y * $w + $x]
        if ($o -eq 0 -or (IsF $x ($y - 1))) { continue }
        for ($k = 1; $k -le 3; $k++) {
            $wy = $y - $k; if ($wy -lt 0) { break }
            if (IsF $x $wy) { [Console]::Error.WriteLine("wall too short above $x,$y"); break }
            $script:WK[$wy * $w + $x] = $k; $script:WO[$wy * $w + $x] = $o
        }
        if (IsF $x ($y - 4)) { [Console]::Error.WriteLine("no border above $x,$y") }
    } }
    for ($y = 0; $y -lt $h; $y++) { for ($x = 0; $x -lt $w; $x++) {
        $i = $y * $w + $x; $o = $script:Own[$i]; $k = $script:WK[$i]
        if ($o -gt 0) {
            $st = $script:Rooms[$o - 1].Floor
            SetT 'Back' $x $y $st.T[($x % 2) + 2 * ($y % 2)] $st.S
            # bottom edge drawn over the last floor row
            if (-not (IsR $x ($y + 1))) {
                if (-not (IsR ($x - 1) $y)) { $t = 161 } elseif (-not (IsR ($x + 1) $y)) { $t = 166 }
                elseif (IsR ($x + 1) ($y + 1)) { $t = 162 } elseif (IsR ($x - 1) ($y + 1)) { $t = 163 } else { $t = 165 }
                SetT 'Front' $x $y $t
            }
        } elseif ($k -gt 0) {
            $st = $script:Rooms[$script:WO[$i] - 1].Wall
            $a = 0; if ($st.Alt) { $a = $x % 2 }
            SetT 'Back' $x $y ($st.T[3 - $k] + $a) $st.S
            if ($k -le 2 -and $st.B[2 - $k] -ge 0) { SetT 'Buildings' $x $y ($st.B[2 - $k] + $a) $st.S }
            # wall ends at an opening
            if (IsF ($x + 1) $y) { SetT 'Buildings' $x $y (@(219, 187, 155)[$k - 1]) }
            elseif (IsF ($x - 1) $y) { SetT 'Buildings' $x $y (@(218, 186, 154)[$k - 1]) }
        } else {
            SetT 'Buildings' $x $y 0
            $e = IsR ($x + 1) $y; $wv = IsR ($x - 1) $y; $s = IsR $x ($y + 1)
            if ($e -and $wv) { [Console]::Error.WriteLine("one-tile gap at $x,$y") }
            $t = -1
            if ($s -and $e) { $t = 194 } elseif ($s -and $wv) { $t = 193 }
            elseif ($e) { if (-not $s -and (IsF ($x + 1) $y) -and -not (IsR ($x + 1) ($y + 1))) { $t = 160 } else { $t = 64 } }
            elseif ($wv) { if (-not $s -and (IsF ($x - 1) $y) -and -not (IsR ($x - 1) ($y + 1))) { $t = 167 } else { $t = 68 } }
            elseif ($s) { $t = 10 }
            elseif (IsR ($x + 1) ($y + 1)) { $t = 9 }
            elseif (IsR ($x - 1) ($y + 1)) { $t = 11 }
            if ($t -ge 0) { SetT 'Front' $x $y $t }
        }
    } }
}

function TileProp([string]$L, [int]$X, [int]$Y, [string]$N, [string]$V) { $script:TileData += , @($L, $X, $Y, $N, $V) }

# closed door on a wall, as the bedroom doors in SamHouse (Y = bottom wall row): placeholder for the third generation's house
function Gen3Door([int]$X, [int]$Y) {
    SetT 'Back' $X ($Y - 2) 92; SetT 'Back' $X ($Y - 1) 124; SetT 'Back' $X $Y 124
    SetT 'Front' $X ($Y - 2) 56; SetT 'Front' $X ($Y - 1) 88; SetT 'Buildings' $X $Y 120
    TileProp 'Buildings' $X $Y 'Action' 'Message MV.Gen3Door'
}

# beds, layered as the painted beds in HaleyHouse and SamHouse; Y = the wall row the headboard hangs on,
# the bed covers the 3 floor rows below it (head and footboard block, the blanket row is walkable)
# single bed, 2 wide: bedding 0 red, 1 yellow, 2 cream; footboard 0 light wood, 1 dark wood
function SingleBed([int]$Bedding, [int]$Foot, [int]$X, [int]$Y) {
    $top = @(352, 354, 358)[$Bedding]; $low = @(384, 386, 390)[$Bedding]; $ft = @(320, 322)[$Foot]
    for ($i = 0; $i -lt 2; $i++) {
        SetT 'Front' ($X + $i) $Y (324 + $i)
        SetT 'Buildings' ($X + $i) ($Y + 1) (356 + $i); SetT 'Front' ($X + $i) ($Y + 1) ($top + $i)
        SetT 'Front' ($X + $i) ($Y + 2) ($low + $i)
        SetT 'Buildings' ($X + $i) ($Y + 3) ($ft + $i)
    }
}
# Emily's double bed, 3 wide
function DoubleBed([int]$X, [int]$Y) {
    for ($i = 0; $i -lt 3; $i++) {
        SetT 'Front' ($X + $i) $Y (739 + $i)
        SetT 'Buildings' ($X + $i) ($Y + 1) (771 + $i); SetT 'Front' ($X + $i) ($Y + 1) (803 + $i)
        SetT 'Front' ($X + $i) ($Y + 2) (835 + $i)
        SetT 'Buildings' ($X + $i) ($Y + 3) (867 + $i)
    }
}
# the old farmhouse crib from farmhouse_tiles, 3 wide: rail on the wall row, cot on the 3 floor rows below
function Crib([int]$X, [int]$Y) {
    for ($i = 0; $i -lt 3; $i++) {
        SetT 'Front' ($X + $i) $Y (185 + $i) $FH
        for ($r = 1; $r -le 3; $r++) { SetT 'Buildings' ($X + $i) ($Y + $r) (185 + 12 * $r + $i) $FH }
    }
}

function Write-House([string]$Dst) {
    $w = $script:MapW; $h = $script:MapH
    $sb = New-Object System.Text.StringBuilder
    $nl = "`r`n"
    $objs = $script:TileData
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8"?>' + $nl)
    [void]$sb.Append(('<map version="1.10" tiledversion="1.11.1" orientation="orthogonal" renderorder="right-down" width="{0}" height="{1}" tilewidth="16" tileheight="16" infinite="0" nextlayerid="{2}" nextobjectid="{3}">' -f $w, $h, 20, ($objs.Count + 1)) + $nl)
    [void]$sb.Append(' <properties>' + $nl)
    foreach ($k in $script:Props.Keys) {
        $v = [Security.SecurityElement]::Escape([string]$script:Props[$k])
        if ($script:Props[$k] -is [bool]) { $v = $v.ToLower(); [void]$sb.Append(('  <property name="{0}" type="bool" value="{1}" />' -f $k, $v) + $nl) }
        else { [void]$sb.Append(('  <property name="{0}" value="{1}" />' -f $k, $v) + $nl) }
    }
    [void]$sb.Append(' </properties>' + $nl)
    foreach ($s in $script:HouseSets) {
        $cnt = ($s[3] / 16) * ($s[4] / 16)
        [void]$sb.Append((' <tileset firstgid="{0}" name="{1}" tilewidth="16" tileheight="16" tilecount="{2}" columns="{3}">' -f $s[1], $s[0], $cnt, $s[2]) + $nl)
        [void]$sb.Append(('  <image source=".{0}.png" width="{1}" height="{2}" />' -f $s[0], $s[3], $s[4]) + $nl)
        [void]$sb.Append(' </tileset>' + $nl)
    }
    $id = 1; $oid = 1
    foreach ($ln in @($script:GL.Keys)) {
        $v = $script:GL[$ln]
        [void]$sb.Append((' <layer id="{0}" name="{1}" width="{2}" height="{3}">' -f $id, $ln, $w, $h) + $nl); $id++
        [void]$sb.Append('  <data encoding="csv">' + $nl)
        $rows = for ($y = 0; $y -lt $h; $y++) { ($v[($y * $w)..($y * $w + $w - 1)]) -join ',' }
        [void]$sb.Append(($rows -join (',' + $nl)) + $nl + '</data>' + $nl + ' </layer>' + $nl)
        $mine = @($objs | Where-Object { $_[0] -eq $ln })
        if ($mine.Count -gt 0) {
            [void]$sb.Append((' <objectgroup id="{0}" name="{1}">' -f $id, $ln) + $nl); $id++
            foreach ($o in $mine) {
                [void]$sb.Append(('  <object id="{0}" name="TileData" x="{1}" y="{2}" width="16" height="16">' -f $oid, ($o[1] * 16), ($o[2] * 16)) + $nl); $oid++
                [void]$sb.Append('   <properties>' + $nl)
                [void]$sb.Append(('    <property name="{0}" value="{1}" />' -f $o[3], [Security.SecurityElement]::Escape($o[4])) + $nl)
                [void]$sb.Append('   </properties>' + $nl + '  </object>' + $nl)
            }
            [void]$sb.Append(' </objectgroup>' + $nl)
        }
    }
    [void]$sb.Append('</map>' + $nl)
    [IO.File]::WriteAllText((Full $Dst), $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

# ---- Felix family: entrance far right, a tree of corridors, rooms at the tips linked to each other,
#      a big greenhouse at the far west end. Leafy wallpapers and warm wood.
function Build-Felix {
    House-Init 82 56
    $script:Props['AmbientLight'] = '80 80 40'; $script:Props['ViewportFollowPlayer'] = $true
    $script:Props['Warp'] = '82 28 Custom_MouseLivingRoom 1 16 82 29 Custom_MouseLivingRoom 1 17'
    $hall = Room 'hall' 45 28 37 2 (FloorWF 402) (WallWF 247)   # trunk from the entrance, dead end at 45
    Link $hall 52 13 2 32        # hub
    Link $hall 36 13 42 2        # north arm
    Link $hall 36 4 2 11         # north-west twig
    Link $hall 36 43 42 2        # south arm
    Link $hall 36 43 2 11        # south-west twig
    $script:F = [ordered]@{}
    $F = $script:F
    $F.G  = Room 'Greenhouse' 3 18 25 22 (FloorTI @(2109)) $GlassWall
    $F.M  = Room 'Master' 30 19 13 9 (FloorWF 410) (WallWF 105)
    $F.N  = Room 'Nursery' 30 32 13 7 (FloorWF 432) (WallWF 101)
    $F.S1 = Room 'StudyFelix' 45 19 5 5 (FloorWF 336) (WallWF 61)
    $F.S2 = Room 'StudyNina' 45 34 5 5 (FloorWF 346) (WallWF 158)
    $F.S3 = Room 'StudyAdele' 26 4 8 5 (FloorWF 404) (WallWF 199)
    $F.S4 = Room 'StudyMandel' 40 4 8 5 (FloorWF 400) (WallWF 51)
    $F.S5 = Room 'StudyBaldwin' 50 4 8 5 (FloorWF 406) (WallWF 248)
    $F.S6 = Room 'StudyJoyce' 50 49 8 5 (FloorWF 628) (WallWF 291)
    $F.S7 = Room 'StudyIvy' 26 49 8 5 (FloorWF 436) (WallWF 108)
    $F.S8 = Room 'StudyLucas' 40 49 8 5 (FloorWF 374) (WallWF 62)
    $F.Ba = Room 'BedAdele' 56 19 7 5 (FloorWF 338) (WallWF 100)
    $F.Bb = Room 'BedMandel' 65 19 7 5 (FloorWF 346) (WallWF 57)
    $F.Bc = Room 'BedBaldwin' 74 19 6 5 (FloorWF 342) (WallWF 7)
    $F.Bd = Room 'BedJoyce' 56 34 7 5 (FloorWF 336) (WallWF 10)
    $F.Be = Room 'BedIvy' 65 34 7 5 (FloorWF 370) (WallWF 107)
    $F.Bf = Room 'BedLucas' 74 34 6 5 (FloorWF 472) (WallWF 3)
    # doorways
    Link $F.M 28 23 2 2; Link $F.N 28 35 2 2; Link $F.N 38 28 2 4
    Link $F.S1 43 21 2 2; Link $F.S2 43 36 2 2; Link $F.S1 50 21 2 2; Link $F.S2 50 36 2 2
    Link $F.M 40 15 2 4; Link $F.N 40 39 2 4
    Link $F.S3 34 7 2 2; Link $F.S4 38 7 2 2; Link $F.S5 48 6 2 2; Link $F.S5 54 9 2 4
    Link $F.Ba 58 15 2 4; Link $F.Bb 63 21 2 2; Link $F.Bb 67 24 2 4; Link $F.Bc 72 20 2 2; Link $F.Bc 76 15 2 4
    Link $F.Bd 58 30 2 4; Link $F.Be 63 36 2 2; Link $F.Be 67 39 2 4; Link $F.Bf 72 35 2 2; Link $F.Bf 76 30 2 4
    Link $F.S7 34 50 2 2; Link $F.S8 38 50 2 2; Link $F.S6 48 51 2 2; Link $F.S6 54 45 2 4
    Link $F.G 26 9 2 9; Link $F.G 26 40 2 9
    Autotile
    Gen3Door 47 27
    Furnish-Felix
}

function Furnish-Felix {
    $HH = 'HaleyHouse'; $AS = 'AnimalShop'; $SR = 'Sunroom'; $GH = 'Greenhouse'; $LH = 'LeahHouse'
    # greenhouse: Felix's soil bed in the middle, Sunroom plants around it
    Stamp $GH 3 9 14 13 7 23 -WithBack
    Stamp $GH 2 6 2 2 4 17; Stamp $GH 15 6 2 2 9 17; Stamp $GH 2 6 2 2 19 17; Stamp $GH 15 6 2 2 24 17
    Stamp $SR 3 3 2 3 13 16                  # fountain against the glass
    Stamp $SR 5 3 3 2 15 16                  # flower box
    Stamp $AS 16 17 2 2 3 21; Stamp $AS 16 17 2 2 3 30
    foreach ($py in 21, 26, 31) { Stamp $HH 9 15 1 2 26 $py }
    Stamp $SR 1 10 3 3 3 36; Stamp $SR 8 10 3 3 23 36
    Stamp $AS 7 13 1 2 25 22; Stamp $AS 8 15 1 2 25 24   # seed barrels
    # master bedroom
    DoubleBed 31 18
    Stamp $HH 6 3 2 2 35 18                  # dresser
    Stamp $HH 9 6 1 3 37 17                  # vanity
    Stamp $LH 11 0 2 5 33 14 -Skip 'Front'   # fireplace
    Rug 31 24 4
    # nursery: cribs for the babies to come
    Crib 31 31; Crib 35 31
    Rug 31 36 5
    Stamp $HH 9 15 1 2 42 32
    # studies
    Stamp $AS 11 13 4 3 45 18; Stamp $AS 4 15 1 2 49 19              # Felix: seed desk and barrel
    Stamp $HH 16 22 2 2 45 33; Stamp $AS 3 17 2 2 47 33; Stamp $HH 9 15 1 2 49 33   # Nina: baskets
    Stamp $HH 2 12 2 4 28 2; Stamp $HH 2 12 2 4 30 2; Stamp $HH 7 14 3 2 31 6        # Adele: books
    Desk 43 5; Stamp $LH 8 2 2 3 45 2; Stamp $LH 8 2 2 3 41 2         # Mandel: writing desk
    Stamp $LH 6 3 1 2 51 4; Stamp $LH 6 3 1 2 55 4; Stamp $LH 2 6 1 2 57 4           # Baldwin: easels
    Stamp $HH 12 22 2 2 55 49; Stamp $HH 9 6 1 3 51 47                             # Joyce: sewing, vanity
    Stamp 'FishShop' 4 4 2 2 30 49; Stamp $HH 16 22 2 2 32 49                        # Ivy: collection
    Stamp 'SebastianRoom' 7 3 2 3 43 47                                               # Lucas: computer
    # kids' bedrooms
    SingleBed 0 0 60 18; SingleBed 2 1 66 18; SingleBed 1 1 78 18     # Adele, Mandel, Baldwin
    SingleBed 2 0 60 33; SingleBed 1 0 66 33; SingleBed 0 1 78 33     # Joyce, Ivy, Lucas
    foreach ($p in @(@(56, 18), @(69, 18), @(74, 18), @(56, 33), @(69, 33), @(74, 33))) { Stamp $HH 6 3 2 2 $p[0] $p[1] }
}

# ---- Kerwin family: entrance far left straight into Sella's kitchen, a ring corridor around it,
#      a barracks row of bedrooms on top and studies below. Stone, brick and dark wood.
function Build-Kerwin {
    House-Init 70 52
    $script:Props['AmbientLight'] = '80 80 40'; $script:Props['ViewportFollowPlayer'] = $true
    $script:Props['Warp'] = '-1 26 Custom_MouseLivingRoom 38 16 -1 27 Custom_MouseLivingRoom 38 17'
    $hall = Room 'hall' 0 26 18 2 (FloorWF 372) (WallWF 12)    # entrance
    Link $hall 16 13 38 2        # ring, top
    Link $hall 16 39 38 2        # ring, bottom
    Link $hall 16 13 2 28        # ring, left
    Link $hall 52 13 2 28        # ring, right
    $script:K = [ordered]@{}
    $K = $script:K
    $K.K  = Room 'Kitchen' 22 19 26 16 (FloorWF 412) (WallWF 193)
    $K.M  = Room 'Master' 2 13 12 9 (FloorWF 348) (WallWF 149)
    $K.N  = Room 'Nursery' 2 32 12 9 (FloorWF 432) (WallWF 289)
    $K.A  = Room 'Armory' 56 13 12 12 (FloorWF 444) (WallWF 12)
    $K.P  = Room 'Pantry' 56 29 12 12 (FloorWF 532) (WallWF 51)
    $K.B1 = Room 'BedMatthew' 2 4 9 5 (FloorWF 400) (WallWF 144)
    $K.B2 = Room 'BedElijah' 13 4 9 5 (FloorWF 404) (WallWF 51)
    $K.B3 = Room 'BedNolan' 24 4 9 5 (FloorWF 434) (WallWF 102)
    $K.B4 = Room 'BedAlyssa' 35 4 9 5 (FloorWF 368) (WallWF 196)
    $K.B5 = Room 'BedReagan' 46 4 9 5 (FloorWF 560) (WallWF 58)
    $K.B6 = Room 'BedLetita' 57 4 9 5 (FloorWF 630) (WallWF 241)
    $K.S1 = Room 'StudyMatthew' 3 45 9 5 (FloorWF 560) (WallWF 255)
    $K.S2 = Room 'StudyElijah' 14 45 9 5 (FloorWF 444) (WallWF 240)
    $K.S3 = Room 'StudyNolan' 25 45 9 5 (FloorWF 434) (WallWF 298)
    $K.S4 = Room 'StudyAlyssa' 36 45 9 5 (FloorWF 368) (WallWF 9)
    $K.S5 = Room 'StudyReagan' 47 45 9 5 (FloorWF 564) (WallWF 254)
    $K.S6 = Room 'StudyLetita' 58 45 9 5 (FloorWF 542) (WallWF 194)
    # doorways
    Link $K.K 18 26 4 2; Link $K.K 48 26 4 2; Link $K.K 34 15 2 4; Link $K.K 34 35 2 4
    Link $K.M 6 22 2 4; Link $K.M 14 16 2 2; Link $K.M 5 9 2 4
    Link $K.N 6 28 2 4; Link $K.N 14 36 2 2; Link $K.N 6 41 2 4
    Link $K.B2 18 9 2 4; Link $K.B3 27 9 2 4; Link $K.B4 38 9 2 4; Link $K.B5 49 9 2 4
    Link $K.B2 11 6 2 2; Link $K.B6 55 6 2 2; Link $K.A 60 9 2 4
    Link $K.A 54 17 2 2; Link $K.P 54 33 2 2
    Link $K.S2 18 41 2 4; Link $K.S3 28 41 2 4; Link $K.S4 39 41 2 4; Link $K.S5 50 41 2 4
    Link $K.S2 12 47 2 2; Link $K.S6 56 47 2 2; Link $K.P 61 41 2 4
    Autotile
    Gen3Door 33 12
    Furnish-Kerwin
}

function Furnish-Kerwin {
    $HH = 'HaleyHouse'; $SH = 'SamHouse'; $SC = 'ScienceHouse'; $AG = 'AdventureGuild'; $AS = 'AnimalShop'
    # Sella's kitchen: four kitchen runs along the north wall, two long work tables each side of the aisle
    Stamp $HH 17 12 6 4 23 16; Stamp $SH 3 1 5 4 29 16
    Stamp $SC 26 5 5 5 37 15; Stamp $HH 17 12 6 4 42 16
    Dining 24 21 7 @(1, 3, 5, 7); Dining 37 21 7 @(1, 3, 5, 7)
    Dining 24 29 7 @(1, 3, 5, 7); Dining 37 29 7 @(1, 3, 5, 7)
    Stamp $AG 1 15 2 2 22 33; Stamp $AG 1 15 2 2 46 33
    foreach ($px in 22, 47) { Stamp $HH 9 15 1 2 $px 19 }
    # master bedroom
    DoubleBed 8 12; Stamp $SH 14 11 2 2 11 12; Stamp $HH 9 15 1 2 3 13
    Rug 3 18 6
    # nursery
    Crib 2 31; Crib 9 31; Rug 3 37 6
    # Kerwin's armory
    Stamp $AG 3 8 2 1 57 11; Stamp $AG 6 8 2 1 64 11; Stamp $AG 11 8 2 1 57 22
    Stamp $AG 4 8 2 2 62 11; Stamp $AG 7 10 1 2 66 13
    Stamp $AG 3 14 4 3 60 18 -WithBack
    Stamp 'Blacksmith' 11 12 2 2 57 14
    # Sella's pantry
    Stamp $AG 1 15 2 2 57 29; Stamp $AG 1 15 2 2 59 29
    Stamp $AS 1 14 4 5 63 29 -WithBack
    Stamp $HH 16 22 2 2 57 38; Stamp $HH 9 15 1 2 66 38
    # kids' bedrooms
    SingleBed 2 1 7 3; SingleBed 0 1 15 3; SingleBed 1 1 29 3; SingleBed 2 0 40 3; SingleBed 0 0 51 3; SingleBed 1 0 62 3
    foreach ($px in 2, 13, 24, 35, 46, 57) { Stamp $SH 14 11 2 2 $px 3 }
    # studies
    Stamp $HH 2 12 2 4 5 43; Stamp $HH 2 12 2 4 9 43; Desk 3 47                   # Matthew: poetry
    Stamp $SC 6 18 6 3 15 47; Stamp 'Blacksmith' 11 12 2 2 20 44                     # Elijah: workbench, anvil
    Stamp 'FishShop' 4 4 2 2 25 45; Stamp 'FishShop' 4 4 2 2 31 45                   # Nolan: aquariums
    Stamp $HH 7 14 3 2 41 45; Stamp $HH 2 12 2 4 36 43                               # Alyssa: globe desk
    Stamp $SH 15 16 2 2 47 45; Stamp $SH 18 16 2 2 53 45; Stamp $SH 19 11 1 2 55 47  # Reagan: drums, keyboard, guitar
    Stamp $HH 9 6 1 3 59 44; Stamp $HH 9 6 1 3 65 44; Rug 59 48 5                    # Letita: mirrors, dance rug
}

# ---------------------------------------------------------------- main

$a = $args
switch ($a[0]) {
    'gen' {
        foreach ($n in 'Back', 'Buildings', 'Front', 'AlwaysFront') { $null = Lay $n }
        Build
        Save-Tmx $a[1] $a[2]
        if ($a.Count -gt 3) { Check $a[3] }
    }
    'house' {
        switch ($a[1]) { 'Felix' { Build-Felix } 'Kerwin' { Build-Kerwin } default { throw "unknown house $($a[1])" } }
        Write-House $a[2]
    }
    'render' { $r = @($a[5..8] | ForEach-Object { [int]$_ }); while ($r.Count -lt 4) { $r += 0 }; Render $a[1] $a[2] ([int]$a[3]) ($a.Count -gt 4 -and $a[4] -eq 'grid') $r[0] $r[1] $r[2] $r[3] }
    'dump' {
        # tile ids per layer; prefix: none = townInterior, B = townInterior_2, P = paths
        $m = Load-Tmx $a[1]; $x0 = [int]$a[2]; $y0 = [int]$a[3]; $dw = [int]$a[4]; $dh = [int]$a[5]
        foreach ($ln in @($m.Layers.Keys)) {
            "== $ln"
            for ($y = $y0; $y -lt $y0 + $dh; $y++) {
                $cells = for ($x = $x0; $x -lt $x0 + $dw; $x++) {
                    $gid = $m.Layers[$ln][$y * $m.W + $x]
                    if ($gid -eq 0) { '.'.PadLeft(6) } else {
                        $ts = Find-Set $m $gid
                        $n = [IO.Path]::GetFileNameWithoutExtension($ts.Source.TrimStart('.'))
                        if ($n -eq 'townInterior') { $px = '' } elseif ($n -eq 'townInterior_2') { $px = 'B' } else { $px = $n.Substring(0, 1).ToUpper() }
                        ($px + ($gid - $ts.First)).PadLeft(6)
                    }
                }
                ('{0,2}:' -f $y) + ($cells -join '')
            }
        }
    }
    default { 'usage: gen <src> <dst> [check] | render <tmx> <out> <scale> [grid]' }
}
