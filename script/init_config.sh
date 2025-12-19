#!/bin/bash

# 初始化 APISIX config.yaml 并自动填充敏感信息

SRC="./apisix/config/config.yaml.example"
DST="./apisix/config/config.yaml"
ENV_FILE=".env"

if [ ! -f "$ENV_FILE" ]; then
    echo ".env file does not exist, please run setup_env.sh first." >&2
    exit 1
fi

if [ -f "$DST" ]; then
    read -p "config.yaml already exists, overwrite? (y/n) " response
    if [[ ! "$response" =~ ^[Yy](es)?$ ]]; then
        echo "Operation cancelled."
        exit 0
    fi
fi

cp "$SRC" "$DST"

# 读取 .env 内容并解析
declare -A env_dict
while IFS='=' read -r key value; do
    if [[ "$key" =~ ^[A-Z0-9_]+$ && -n "$value" ]]; then
        env_dict["$key"]="$value"
    fi
done < <(grep '=' "$ENV_FILE")

# 获取环境变量值
nacos_password="${env_dict[NACOS_PASSWORD]}"
if [ -z "$nacos_password" ]; then
    nacos_password="nacos"
fi
apisix_admin_key="${env_dict[APISIX_ADMIN_KEY]}"
apisix_keyring1="${env_dict[APISIX_KEYRING_1]}"
apisix_keyring2="${env_dict[APISIX_KEYRING_2]}"

# 替换 config.yaml 内容
sed -i "s|<password>|$nacos_password|g" "$DST"
sed -i "s|<APISIX_ADMIN_KEY>|$apisix_admin_key|g" "$DST"
sed -i "s|<APISIX_KEYRING_1>|$apisix_keyring1|g" "$DST"
sed -i "s|<APISIX_KEYRING_2>|$apisix_keyring2|g" "$DST"
sed -i "s|<replace_with_password_here>|$nacos_password|g" "$DST"

echo ""
echo "Generated config.yaml and automatically filled sensitive information."