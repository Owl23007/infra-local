# PowerShell 脚本：生成 Nacos 的认证密钥和 identity 配置

if (Test-Path ".env") {
    $response = Read-Host ".env file already exists. Overwrite? (y/n)"
    if ($response -notmatch "^[Yy](es)?$") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
}

# 生成符合 Nacos JWT 要求的 token（32 字节随机数据 → Base64）
function Generate-NacosJwtSecret {
    $randomBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($randomBytes)
    $base64Token = [Convert]::ToBase64String($randomBytes)
    $rng.Dispose()
    return $base64Token
}

# 生成 identity value
function Generate-RandomIdentityValue {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $value = -join ((1..32) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    return $value
}

# 固定 identity key
$nacosIdentityKey = "serverIdentity"

# 生成
$nacosToken = Generate-NacosJwtSecret          # Base64 编码的 32 字节随机数据
$nacosIdentityValue = Generate-RandomIdentityValue

# 输出
Write-Host "NACOS_AUTH_TOKEN (JWT Secret, Base64): $nacosToken" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_KEY: $nacosIdentityKey" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_VALUE: $nacosIdentityValue" -ForegroundColor Green

# 写入 .env
$envContent = @"
NACOS_AUTH_TOKEN=$nacosToken
NACOS_AUTH_IDENTITY_KEY=$nacosIdentityKey
NACOS_AUTH_IDENTITY_VALUE=$nacosIdentityValue
NACOS_USER=nacos
NACOS_PASSWORD=your_nacos_password_here
"@

# 使用 UTF-8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines("$PWD\.env", $envContent -split "`r?`n", $utf8NoBom)

Write-Host ".env file generated successfully!" -ForegroundColor Cyan