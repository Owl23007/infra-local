#!/bin/bash

if [ -f ".env" ]; then
    read -p ".env file already exists. Overwrite? (y/n) " response
    if [[ ! "$response" =~ ^[Yy](es)?$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

generate_base64_secret() {
    openssl rand -base64 32
}

generate_random_string() {
    local length=${1:-32}
    tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' < /dev/urandom | head -c "$length"
}

generate_hex_key() {
    openssl rand -hex 8
}

nacos_identity_key="serverIdentity"

nacos_auth_token=$(generate_base64_secret)
nacos_identity_value=$(generate_random_string)
apisix_admin_key=$(generate_base64_secret)
apisix_keyring1=$(generate_hex_key)
apisix_keyring2=$(generate_hex_key)

echo ""
echo "Generated Secrets:"
echo "NACOS_AUTH_TOKEN (Base64, 32B): $nacos_auth_token"
echo "NACOS_AUTH_IDENTITY_KEY: $nacos_identity_key"
echo "NACOS_AUTH_IDENTITY_VALUE: $nacos_identity_value"
echo "APISIX_ADMIN_KEY: $apisix_admin_key"
echo "APISIX_KEYRING_1 (Hex, 16 chars): $apisix_keyring1"
echo "APISIX_KEYRING_2 (Hex, 16 chars): $apisix_keyring2"

cat > .env << EOF
# Nacos Authentication
NACOS_AUTH_TOKEN=$nacos_auth_token
NACOS_AUTH_IDENTITY_KEY=$nacos_identity_key
NACOS_AUTH_IDENTITY_VALUE=$nacos_identity_value

NACOS_PASSWORD=<replace_with_password_here>

# APISIX Configuration
APISIX_ADMIN_KEY=$apisix_admin_key

# APISIX Keyring (16 hex chars for AES-128-CBC)
APISIX_KEYRING_1=$apisix_keyring1
APISIX_KEYRING_2=$apisix_keyring2
EOF

echo ""
echo ".env file generated successfully at: $(pwd)/.env"
echo "Keep this file secure and DO NOT commit to version control!"

echo ""
echo "Next Steps:"
echo "1. Start Nacos: docker-compose up -d nacos"
echo "2. Access Nacos UI at http://localhost:8848/nacos (default user/pass: nacos/nacos)"
echo "3. Change the password for user 'nacos' in Nacos UI."
echo "4. Update NACOS_PASSWORD in .env file with the new password."
echo "5. Restart the containers: docker-compose up -d"

read -p "Open Nacos UI in browser now? (y/n) " response
if [[ "$response" =~ ^[Yy](es)?$ ]]; then
    echo "Starting Nacos container..."
    docker-compose up -d nacos

    health_url="http://localhost:8848/nacos"
    max_retries=30
    retry=0

    echo "Waiting for Nacos to become ready..."
    while [ $retry -lt $max_retries ]; do
        if curl -s "$health_url" | grep -q "Nacos"; then
            echo ""
            echo "Nacos started successfully!"
            break
        fi
        retry=$((retry + 1))
        echo -n "."
        sleep 1
    done

    echo ""

    if [ $retry -ge $max_retries ]; then
        echo "Nacos startup timeout. Opening UI anyway..."
    else
        echo "Opening Nacos UI in browser..."
    fi

    # Open browser (assuming Linux with xdg-open)
    if command -v xdg-open > /dev/null; then
        xdg-open "$health_url"
    else
        echo "Please open $health_url in your browser."
    fi
fi