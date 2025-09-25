
if (Test-Path ".env") {
    $response = Read-Host ".env file already exists. Overwrite? (y/n)"
    if ($response -notmatch "^[Yy](es)?$") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }
}

function Generate-Base64Secret {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return [Convert]::ToBase64String($bytes)
}

function Generate-RandomString {
    param([int]$Length = 32)
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-='
    return -join ((1..$Length) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

function Generate-HexKey {
    $bytes = New-Object byte[] 16  # 16 bytes = 128 bits
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return [BitConverter]::ToString($bytes).Replace("-", "").ToLower()
}

$nacosIdentityKey = "serverIdentity"

$nacosAuthToken      = Generate-Base64Secret          # Nacos JWT Secret
$nacosIdentityValue  = Generate-RandomString         # Identity value
$apisixAdminKey      = Generate-Base64Secret          # APISIX Admin API Key
$encryptionKey1      = Generate-HexKey                # APISIX 加密密钥 1
$encryptionKey2      = Generate-HexKey                # APISIX 加密密钥 2（用于轮换）

$nacosPassword = "nacos"  # 初始默认密码

Write-Host "`nGenerated Secrets:" -ForegroundColor Cyan
Write-Host "NACOS_AUTH_TOKEN (Base64, 32B): $nacosAuthToken" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_KEY: $nacosIdentityKey" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_VALUE: $nacosIdentityValue" -ForegroundColor Green
Write-Host "NACOS_USER: nacos" -ForegroundColor Green
Write-Host "NACOS_PASSWORD: $nacosPassword (default, change in UI!)" -ForegroundColor Green
Write-Host "APISIX_ADMIN_KEY: $apisixAdminKey" -ForegroundColor Green
Write-Host "APISIX_ENCRYPTION_KEY_1 (hex): $encryptionKey1" -ForegroundColor Green
Write-Host "APISIX_ENCRYPTION_KEY_2 (hex): $encryptionKey2" -ForegroundColor Green

$envContent = @"
# Nacos Authentication
NACOS_AUTH_TOKEN=$nacosAuthToken
NACOS_AUTH_IDENTITY_KEY=$nacosIdentityKey
NACOS_AUTH_IDENTITY_VALUE=$nacosIdentityValue
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText("$PWD\.env", $envContent, $utf8NoBom)

Write-Host "`n.env file generated successfully at: $PWD\.env" -ForegroundColor Cyan
Write-Host "Keep this file secure and DO NOT commit to version control!" -ForegroundColor Yellow

Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Start Nacos: docker-compose up -d nacos" -ForegroundColor Green
Write-Host "2. Access Nacos UI at http://localhost:8080/#/login (default user/pass: nacos/nacos)" -ForegroundColor Green
Write-Host "3. Change the password for user 'nacos' in Nacos UI." -ForegroundColor Green
Write-Host "4. Update NACOS_PASSWORD in .env file with the new password." -ForegroundColor Green
Write-Host "5. Restart the containers: docker-compose up -d" -ForegroundColor Green