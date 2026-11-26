<#
.SYNOPSIS
    将官方 CarWithin IPA（或本地目录）中的 MFi 配件认证文件注入到自编译的未签名 IPA 中。

.DESCRIPTION
    从官方旧版 IPA（-SourceIpa）或本地目录（-IdentityDir）读取以下 3 个文件：
      - certificate.p7b
      - leaf.cer
      - private.x963
    并以原地更新 ZipArchive 的方式写入新 IPA 的 Payload/<App>.app/ 根目录。
    不会解压重压整个包，从而完整保留 macOS 打包的 Unix 可执行权限与符号链接。

.EXAMPLE
    .\Tools\inject_identity.ps1 `
        -SourceIpa .\CarWithin-1.0.5-unsigned.ipa `
        -TargetIpa .\CarWithin-1.0.5-b17-c9b2620-unsigned.ipa

.EXAMPLE
    .\Tools\inject_identity.ps1 `
        -IdentityDir .\IdentityImport `
        -TargetIpa .\CarWithin-1.0.5-b17-c9b2620-unsigned.ipa `
        -OutputIpa .\CarWithin-pr45-ready.ipa -Force
#>

[CmdletBinding(DefaultParameterSetName = 'FromIpa')]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetIpa,

    [Parameter(Mandatory = $true, ParameterSetName = 'FromIpa')]
    [string]$SourceIpa,

    [Parameter(Mandatory = $true, ParameterSetName = 'FromDir')]
    [string]$IdentityDir,

    [Parameter(Mandatory = $false)]
    [string]$OutputIpa,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$RequiredFiles = @('certificate.p7b', 'leaf.cer', 'private.x963')
$MaxIdentityBytes = 65536

function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Repair-UnixZipHostOS([string]$ZipPath) {
    # .NET ZipArchive on Windows writes version_made_by host OS = 0 (MS-DOS),
    # which causes Unix/iOS unzippers to ignore Unix mode bits in ExternalAttributes.
    # Walk the ZIP Central Directory and set host OS = 3 (Unix) for entries with Unix mode bits.
    $fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try {
        $len = $fs.Length
        $searchLen = [int][Math]::Min($len, 65557)
        $tail = New-Object byte[] $searchLen
        $fs.Seek($len - $searchLen, [System.IO.SeekOrigin]::Begin) | Out-Null
        [void]$fs.Read($tail, 0, $searchLen)

        $eocdOffset = -1
        for ($i = $searchLen - 22; $i -ge 0; $i--) {
            if ($tail[$i] -eq 0x50 -and $tail[$i + 1] -eq 0x4B -and $tail[$i + 2] -eq 0x05 -and $tail[$i + 3] -eq 0x06) {
                $commentLen = [BitConverter]::ToUInt16($tail, $i + 20)
                if ($i + 22 + $commentLen -eq $searchLen) {
                    $eocdOffset = $i
                    break
                }
            }
        }
        if ($eocdOffset -lt 0) { throw "无法定位 ZIP EOCD 记录。" }

        $cdEntries = [BitConverter]::ToUInt16($tail, $eocdOffset + 10)
        $cdSize = [BitConverter]::ToUInt32($tail, $eocdOffset + 12)
        $cdOffset = [BitConverter]::ToUInt32($tail, $eocdOffset + 16)
        if ($cdEntries -eq 0xFFFF -or $cdSize -eq 0xFFFFFFFF -or $cdOffset -eq 0xFFFFFFFF) {
            return # ZIP64 not expected for small iOS IPA
        }

        $cdBuf = New-Object byte[] $cdSize
        $fs.Seek($cdOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        [void]$fs.Read($cdBuf, 0, $cdBuf.Length)

        $pos = 0
        for ($idx = 0; $idx -lt $cdEntries; $idx++) {
            if ($pos + 46 -gt $cdBuf.Length) { throw "ZIP 中央目录截断。" }
            if ($cdBuf[$pos] -ne 0x50 -or $cdBuf[$pos + 1] -ne 0x4B -or $cdBuf[$pos + 2] -ne 0x01 -or $cdBuf[$pos + 3] -ne 0x02) {
                throw "ZIP 中央目录签名无效。"
            }
            $nameLen = [BitConverter]::ToUInt16($cdBuf, $pos + 28)
            $extraLen = [BitConverter]::ToUInt16($cdBuf, $pos + 30)
            $commentLen = [BitConverter]::ToUInt16($cdBuf, $pos + 32)
            $unixMode = [BitConverter]::ToUInt16($cdBuf, $pos + 40)
            if ($unixMode -ne 0) {
                $cdBuf[$pos + 5] = 3 # 3 = UNIX
            }
            $pos += 46 + $nameLen + $extraLen + $commentLen
        }

        $fs.Seek($cdOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fs.Write($cdBuf, 0, $cdBuf.Length)
    } finally {
        $fs.Dispose()
    }
}

function Read-EntryBytes([System.IO.Compression.ZipArchiveEntry]$Entry) {
    $stream = $Entry.Open()
    try {
        $ms = New-Object System.IO.MemoryStream
        try {
            $stream.CopyTo($ms)
            return $ms.ToArray()
        } finally {
            $ms.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$targetPath = Resolve-FullPath $TargetIpa
if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    throw "找不到目标 IPA：$targetPath"
}

if ([string]::IsNullOrWhiteSpace($OutputIpa)) {
    $dir = [System.IO.Path]::GetDirectoryName($targetPath)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($targetPath)
    $outputPath = Join-Path $dir "$stem-with-identity.ipa"
} else {
    $outputPath = Resolve-FullPath $OutputIpa
}

if ([string]::Equals($targetPath, $outputPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "输出路径不能与 TargetIpa 相同，请指定新的 -OutputIpa 路径。"
}

if ((Test-Path -LiteralPath $outputPath) -and (-not $Force)) {
    throw "输出文件已存在：$outputPath（如需覆盖请追加 -Force）"
}

# 1. 读取 3 个配件认证文件
$identityBlobs = @{}

if ($PSCmdlet.ParameterSetName -eq 'FromIpa') {
    $sourcePath = Resolve-FullPath $SourceIpa
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "找不到来源 IPA：$sourcePath"
    }

    Write-Host "正在从官方 IPA 提取认证文件：$sourcePath"
    $srcZip = [System.IO.Compression.ZipFile]::OpenRead($sourcePath)
    try {
        $infoEntries = @($srcZip.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/Info\.plist$' })
        if ($infoEntries.Count -ne 1) {
            throw "来源 IPA 结构异常：未找到唯一的主应用 Payload/*.app/Info.plist。"
        }
        $srcAppPrefix = $infoEntries[0].FullName -replace '/Info\.plist$', ''

        foreach ($name in $RequiredFiles) {
            $entryName = "$srcAppPrefix/$name"
            $entry = $srcZip.GetEntry($entryName)
            if ($null -eq $entry) {
                throw "来源 IPA 中缺少必需文件：$entryName"
            }
            $bytes = Read-EntryBytes $entry
            if ($bytes.Length -eq 0 -or $bytes.Length -gt $MaxIdentityBytes) {
                throw "来源文件大小异常：$name（$($bytes.Length) 字节）"
            }
            $identityBlobs[$name] = $bytes
            Write-Host "  已读取 $entryName ($($bytes.Length) 字节)"
        }
    } finally {
        $srcZip.Dispose()
    }
} else {
    $dirPath = Resolve-FullPath $IdentityDir
    if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) {
        throw "找不到认证文件目录：$dirPath"
    }

    Write-Host "正在从目录读取认证文件：$dirPath"
    foreach ($name in $RequiredFiles) {
        $filePath = Join-Path $dirPath $name
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "目录中缺少必需文件：$filePath"
        }
        $bytes = [System.IO.File]::ReadAllBytes($filePath)
        if ($bytes.Length -eq 0 -or $bytes.Length -gt $MaxIdentityBytes) {
            throw "文件大小异常：$filePath（$($bytes.Length) 字节）"
        }
        $identityBlobs[$name] = $bytes
        Write-Host "  已读取 $name ($($bytes.Length) 字节)"
    }
}

# 2. 复制目标 IPA 并原地注入（保留原有条目的 Unix 可执行权限）
$outputDir = [System.IO.Path]::GetDirectoryName($outputPath)
if (-not [string]::IsNullOrEmpty($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
Copy-Item -LiteralPath $targetPath -Destination $outputPath -Force

$injectedPrefix = ''
try {
    $dstZip = [System.IO.Compression.ZipFile]::Open($outputPath, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        $infoEntries = @($dstZip.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/Info\.plist$' })
        if ($infoEntries.Count -ne 1) {
            throw "目标 IPA 结构异常：未找到唯一的主应用 Payload/*.app/Info.plist。"
        }
        $injectedPrefix = $infoEntries[0].FullName -replace '/Info\.plist$', ''

        foreach ($name in $RequiredFiles) {
            $entryName = "$injectedPrefix/$name"
            $existing = $dstZip.GetEntry($entryName)
            if ($null -ne $existing) {
                $existing.Delete()
            }
            $newEntry = $dstZip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            # 设为标准 Unix 普通文件权限 0644 (-rw-r--r--)
            $newEntry.ExternalAttributes = ([int]0x81A4 -shl 16)
            $outStream = $newEntry.Open()
            try {
                $bytes = $identityBlobs[$name]
                $outStream.Write($bytes, 0, $bytes.Length)
            } finally {
                $outStream.Dispose()
            }
            Write-Host "  已写入 $entryName ($($bytes.Length) 字节)"
        }
    } finally {
        $dstZip.Dispose()
    }
    Repair-UnixZipHostOS $outputPath
} catch {
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
    throw
}

# 3. 回读校验
$verifyZip = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
try {
    foreach ($name in $RequiredFiles) {
        $entryName = "$injectedPrefix/$name"
        $entry = $verifyZip.GetEntry($entryName)
        if ($null -eq $entry -or $entry.Length -ne $identityBlobs[$name].Length) {
            throw "校验失败：$entryName 未正确写入。"
        }
    }
} finally {
    $verifyZip.Dispose()
}

$hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ""
Write-Host "完成！已生成带认证身份的未签名 IPA：" -ForegroundColor Green
Write-Host "  路径：$outputPath"
Write-Host "  SHA-256：$hash"
Write-Host "下一步：使用你的侧载工具（如 Sideloadly / 爱思 / 自签工具 / 巨魔等）签名安装到 iPhone。"
