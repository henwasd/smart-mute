param(
    [Parameter(Position = 0)]
    [string]$Message = "",

    [ValidateSet("patch", "minor", "major")]
    [string]$Bump = "patch",

    [string]$Version = "",

    [switch]$NoPush
)

$ErrorActionPreference = "Stop"

# 1. Solicitar mensagem de commit caso não tenha sido informada
if ([string]::IsNullOrWhiteSpace($Message)) {
    $Message = Read-Host "Digite a mensagem do commit para esta release"
    if ([string]::IsNullOrWhiteSpace($Message)) {
        Write-Error "A mensagem de commit é obrigatória."
        exit 1
    }
}

$manifestPath = Join-Path $PSScriptRoot "manifest.json"
if (-not (Test-Path $manifestPath)) {
    Write-Error "Arquivo manifest.json não encontrado em $PSScriptRoot"
    exit 1
}

# 2. Ler versão atual do manifest.json
$manifestRaw = Get-Content $manifestPath -Raw -Encoding UTF8
$manifestJson = $manifestRaw | ConvertFrom-Json
$currentVersion = [string]$manifestJson.version

if ([string]::IsNullOrWhiteSpace($Version)) {
    $parts = $currentVersion.Split('.') | ForEach-Object { [int]$_ }
    while ($parts.Count -lt 3) {
        $parts += 0
    }

    $major = $parts[0]
    $minor = $parts[1]
    $patch = $parts[2]

    switch ($Bump) {
        "major" {
            $major++
            $minor = 0
            $patch = 0
        }
        "minor" {
            $minor++
            $patch = 0
        }
        "patch" {
            $patch++
        }
    }

    $newVersion = "$major.$minor.$patch"
} else {
    $newVersion = $Version.TrimStart('v')
}

$tagName = "v$newVersion"

# Verificar se a tag já existe
$existingTag = git tag -l $tagName
if ($existingTag) {
    Write-Error "A tag $tagName já existe no repositório. Escolha outra versão."
    exit 1
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Smart Mute Release Automation" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Versão atual : $currentVersion"
Write-Host "Nova versão  : $newVersion ($tagName)"
Write-Host "Mensagem     : $Message"
Write-Host "-----------------------------------------" -ForegroundColor Cyan

# 3. Atualizar manifest.json preservando formatação e UTF-8 sem BOM
$updatedManifestRaw = [regex]::Replace(
    $manifestRaw,
    '("version"\s*:\s*)"[^"]+"',
    "`$1`"$newVersion`""
)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $updatedManifestRaw, $utf8NoBom)
Write-Host "[1/4] manifest.json atualizado para a versão $newVersion" -ForegroundColor Green

# 4. Gerar pacote .zip limpo para a Chrome Web Store
$distDir = Join-Path $PSScriptRoot "dist"
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir | Out-Null
}

$zipFileName = "smart-mute-v$newVersion.zip"
$zipFilePath = Join-Path $distDir $zipFileName
if (Test-Path $zipFilePath) {
    Remove-Item $zipFilePath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$extensionFiles = @(
    "manifest.json",
    "background.js",
    "popup.html",
    "popup.css",
    "popup.js",
    "icon16.png",
    "icon48.png",
    "icon128.png"
)

$zipStream = [System.IO.File]::Open($zipFilePath, [System.IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($zipStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        foreach ($relPath in $extensionFiles) {
            $fullPath = Join-Path $PSScriptRoot $relPath
            if (Test-Path $fullPath) {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $fullPath, $relPath) | Out-Null
            }
        }

        $localesDir = Join-Path $PSScriptRoot "_locales"
        if (Test-Path $localesDir) {
            $localeFiles = Get-ChildItem -Path $localesDir -Recurse -File
            foreach ($file in $localeFiles) {
                $relPath = $file.FullName.Substring($PSScriptRoot.Length + 1).Replace('\', '/')
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relPath) | Out-Null
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $zipStream.Dispose()
}

Write-Host "[2/4] Pacote gerado com sucesso: dist/$zipFileName" -ForegroundColor Green

# 5. Criar commit e tag no Git
git add -A
git commit -m "v${newVersion}: $Message"
git tag -a $tagName -m "Release $tagName - $Message"
Write-Host "[3/4] Commit e tag $tagName criados localmente" -ForegroundColor Green

# 6. Push para o GitHub (dispara o GitHub Actions)
if (-not $NoPush) {
    $currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    git push origin $currentBranch
    git push origin $tagName
    Write-Host "[4/4] Push enviado para origin/$currentBranch com a tag $tagName!" -ForegroundColor Green
} else {
    Write-Host "[4/4] Push ignorado (-NoPush ativado)." -ForegroundColor Yellow
}

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " Release $tagName concluída!" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
