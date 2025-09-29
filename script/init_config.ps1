# 初始化 APISIX config.yaml 并自动填充敏感信息

$src = ".\apisix\config\config.yaml.example"
$dst = ".\apisix\config\config.yaml"
$envFile = ".env"

if (!(Test-Path $envFile)) {
    Write-Host ".env file does not exist, please run setup_env.ps1 first." -ForegroundColor Red
    exit
}

if (Test-Path $dst) {
    $response = Read-Host "config.yaml already exists, overwrite? (y/n)"
    if ($response -notmatch "^[Yy](es)?$") {
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit
    }
}

Copy-Item $src $dst -Force

# 读取 .env 内容
$env = Get-Content $envFile | Where-Object { $_ -match "=" }
$envDict = @{}
foreach ($line in $env) {
    $parts = $line -split "=", 2
    if ($parts.Length -eq 2) {
        $envDict[$parts[0].Trim()] = $parts[1].Trim()
    }
}

# 获取 NACOS_PASSWORD（如无则用 nacos），APISIX_ADMIN_KEY
$nacosPassword = $envDict["NACOS_PASSWORD"]
if (-not $nacosPassword) { $nacosPassword = "nacos" }
$apisixAdminKey = $envDict["APISIX_ADMIN_KEY"]
$apisixKeyring1 = $envDict["APISIX_KEYRING_1"]
$apisixKeyring2 = $envDict["APISIX_KEYRING_2"]

# 替换 config.yaml 内容
$config = Get-Content $dst -Raw
$config = $config -replace "<password>", $nacosPassword
$config = $config -replace "<APISIX_ADMIN_KEY>", $apisixAdminKey
$config = $config -replace "<APISIX_KEYRING_1>", $apisixKeyring1
$config = $config -replace "<APISIX_KEYRING_2>", $apisixKeyring2
Set-Content $dst $config

Write-Host "`nGenerated config.yaml and automatically filled sensitive information." -ForegroundColor Cyan