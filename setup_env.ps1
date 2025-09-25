# PowerShell 脚本：生成 Nacos、APISIX 所需的密钥和配置

if (Test-Path ".env") {
    $response = Read-Host ".env file already exists. Overwrite? (y/n)"
    if ($response -notmatch "^[Yy](es)?$") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
}

# 生成 Base64 编码的 32 字节随机密钥（用于 JWT Secret、Admin Key 等）
function Generate-Base64Secret {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return [Convert]::ToBase64String($bytes)
}

# 生成 32 位强随机 ASCII 字符串（用于 identity value、Nacos 用户密码等）
function Generate-RandomString {
    param([int]$Length = 32)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-='
    return -join ((1..$Length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# 生成 32 位小写十六进制字符串（用于 APISIX data_encryption.keyring）
function Generate-HexKey {
    $bytes = New-Object byte[] 16  # 16 bytes = 128 bits
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return [BitConverter]::ToString($bytes).Replace("-", "").ToLower()
}

# 固定值
$nacosIdentityKey = "serverIdentity"

# 生成所有密钥
$nacosAuthToken      = Generate-Base64Secret          # Nacos JWT Secret
$nacosIdentityValue  = Generate-RandomString         # Identity value
$apisixAdminKey      = Generate-Base64Secret          # APISIX Admin API Key
$encryptionKey1      = Generate-HexKey                # APISIX 加密密钥 1
$encryptionKey2      = Generate-HexKey                # APISIX 加密密钥 2（用于轮换）

# 输出到控制台
Write-Host "`nGenerated Secrets:" -ForegroundColor Cyan
Write-Host "NACOS_AUTH_TOKEN (Base64, 32B): $nacosAuthToken" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_KEY: $nacosIdentityKey" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_VALUE: $nacosIdentityValue" -ForegroundColor Green
Write-Host "NACOS_USER: nacos" -ForegroundColor Green
Write-Host "NACOS_PASSWORD: $nacosPassword" -ForegroundColor Green
Write-Host "APISIX_ADMIN_KEY: $apisixAdminKey" -ForegroundColor Green
Write-Host "APISIX_ENCRYPTION_KEY_1 (hex): $encryptionKey1" -ForegroundColor Green
Write-Host "APISIX_ENCRYPTION_KEY_2 (hex): $encryptionKey2" -ForegroundColor Green

# 构建 .env 内容（UTF-8 无 BOM）
$envContent = @"
# Nacos Authentication
NACOS_AUTH_TOKEN=$nacosAuthToken
NACOS_AUTH_IDENTITY_KEY=$nacosIdentityKey
NACOS_AUTH_IDENTITY_VALUE=$nacosIdentityValue
NACOS_USER=nacos
NACOS_PASSWORD= your_nacos_password_here

# APISIX Admin API
APISIX_ADMIN_KEY=$apisixAdminKey

# APISIX Data Encryption (keyring for etcd field encryption)
APISIX_ENCRYPTION_KEY_1=$encryptionKey1
APISIX_ENCRYPTION_KEY_2=$encryptionKey2
"@

# 写入 .env 文件（UTF-8 无 BOM）
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# [System.IO.File]::WriteAllText("$PWD\.env", $envContent, $utf8NoBom)

Write-Host "`n.env file generated successfully at: $PWD\.env" -ForegroundColor Cyan
Write-Host "Keep this file secure and DO NOT commit to version control!" -ForegroundColor Yellow
# 下一步启动nacos并设置密码然后更新.env文件
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "1. Start Nacos: docker-compose up -d nacos" -ForegroundColor Green
Write-Host "2. Access Nacos UI at http://localhost:8080/#/login (default user/pass: nacos/nacos)" -ForegroundColor Green
Write-Host "3. Change the password for user 'nacos' in Nacos UI." -ForegroundColor Green
Write-Host "4. Update NACOS_PASSWORD in .env file with the new password." -ForegroundColor Green
Write-Host "5. Restart the containers: docker-compose up -d" -ForegroundColor Green