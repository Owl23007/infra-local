
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
    $bytes = New-Object byte[] 8  # 8 bytes for 16 hex chars
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return [BitConverter]::ToString($bytes).Replace("-", "").ToLower()
}

$nacosIdentityKey = "serverIdentity"

$nacosAuthToken      = Generate-Base64Secret          # Nacos JWT Secret
$nacosIdentityValue  = Generate-RandomString         # Identity value
$apisixAdminKey      = Generate-Base64Secret          # APISIX Admin API Key
$apisixKeyring1      = Generate-HexKey                # APISIX Keyring Key 1 (16 hex chars)
$apisixKeyring2      = Generate-HexKey                # APISIX Keyring Key 2 (16 hex chars)

Write-Host "`nGenerated Secrets:" -ForegroundColor Cyan
Write-Host "NACOS_AUTH_TOKEN (Base64, 32B): $nacosAuthToken" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_KEY: $nacosIdentityKey" -ForegroundColor Green
Write-Host "NACOS_AUTH_IDENTITY_VALUE: $nacosIdentityValue" -ForegroundColor Green
Write-Host "APISIX_ADMIN_KEY: $apisixAdminKey" -ForegroundColor Green
Write-Host "APISIX_KEYRING_1 (Hex, 16 chars): $apisixKeyring1" -ForegroundColor Green
Write-Host "APISIX_KEYRING_2 (Hex, 16 chars): $apisixKeyring2" -ForegroundColor Green

$envContent = @"
# Nacos Authentication
NACOS_AUTH_TOKEN=$nacosAuthToken
NACOS_AUTH_IDENTITY_KEY=$nacosIdentityKey
NACOS_AUTH_IDENTITY_VALUE=$nacosIdentityValue

NACOS_PASSWORD=<replace_with_password_here>

# APISIX Configuration
APISIX_ADMIN_KEY=$apisixAdminKey

# APISIX Keyring (16 hex chars for AES-128-CBC)
APISIX_KEYRING_1=$apisixKeyring1
APISIX_KEYRING_2=$apisixKeyring2

"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
#[System.IO.File]::WriteAllText("$PWD\.env", $envContent, $utf8NoBom)

Write-Host "`n.env file generated successfully at: $PWD\.env" -ForegroundColor Cyan
Write-Host "Keep this file secure and DO NOT commit to version control!" -ForegroundColor Yellow

Write-Host "`nNext Steps:" -ForegroundColor Cyan
Write-Host "1. Start Nacos: docker-compose up -d nacos" -ForegroundColor Green
Write-Host "2. Access Nacos UI at http://localhost:8080/#/login (default user/pass: nacos/nacos)" -ForegroundColor Green
Write-Host "3. Change the password for user 'nacos' in Nacos UI." -ForegroundColor Green
Write-Host "4. Update NACOS_PASSWORD in .env file with the new password." -ForegroundColor Green
Write-Host "5. Restart the containers: docker-compose up -d" -ForegroundColor Green

# check if user wants to open nacos ui after docker-compose up -d nacos
$response = Read-Host "`nOpen Nacos UI in browser now? (y/n)"
if ($response -match "^[Yy](es)?$") {
    Write-Host "Starting Nacos container..." -ForegroundColor Green
    docker-compose up -d nacos

    # Use the NEW health check endpoint for Nacos >=2.2.0
    $healthUrl = "http://localhost:8080/#/login"
    $maxRetries = 30
    $retry = 0

    Write-Host "Waiting for Nacos to become ready..." -ForegroundColor Cyan
    while ($retry -lt $maxRetries) {
        try {
            $resp = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 20
         if ($resp.StatusCode -eq 200 -and $resp.Content -match "Nacos") {
                Write-Host " "
                Write-Host "Nacos started successfully!" -ForegroundColor Green
                break
            }
        } catch {
            # Ignore and retry
        }
        $retry++
        Write-Host "." -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }

    Write-Host ""  # New line

    if ($retry -ge $maxRetries) {
        Write-Host "Nacos startup timeout. Opening UI anyway..." -ForegroundColor DarkYellow
    } else {
        Write-Host "Opening Nacos UI in browser..." -ForegroundColor Cyan
    }

    # Open your confirmed UI URL
    Start-Process "http://localhost:8080/#/login"
}