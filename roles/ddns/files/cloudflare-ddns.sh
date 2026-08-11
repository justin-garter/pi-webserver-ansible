#!/bin/bash
# Managed by Ansible — roles/ddns
set -euo pipefail
source /etc/cloudflare-ddns/config

CURRENT_IP=$(curl -s -4 https://ifconfig.me)
LAST_IP_FILE="/var/lib/cloudflare-ddns/last_ip"
mkdir -p /var/lib/cloudflare-ddns

if [ -f "$LAST_IP_FILE" ]; then
    LAST_IP=$(cat "$LAST_IP_FILE")
else
    LAST_IP=""
fi

if [ "$CURRENT_IP" == "$LAST_IP" ]; then
    echo "$(date): IP unchanged ($CURRENT_IP), skipping."
    exit 0
fi

echo "$(date): IP changed from '$LAST_IP' to '$CURRENT_IP', updating Cloudflare..."
ALL_SUCCEEDED=true

for RECORD_NAME in $CF_RECORD_NAMES; do
    RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=A&name=$RECORD_NAME" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result[0].id')

    if [ "$RECORD_ID" == "null" ] || [ -z "$RECORD_ID" ]; then
        echo "$(date): ERROR - could not find DNS record ID for $RECORD_NAME"
        ALL_SUCCEEDED=false
        continue
    fi

    # Read the existing proxied flag rather than hardcoding it. The apex is
    # proxied; the vpn record must stay unproxied because Cloudflare cannot
    # forward WireGuard's UDP. Hardcoding silently breaks one of them on the
    # next IP change.
    CURRENT_PROXIED=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" | jq -r '.result.proxied')

    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$RECORD_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":$CURRENT_PROXIED}")

    if [ "$(echo "$RESPONSE" | jq -r '.success')" == "true" ]; then
        echo "$(date): Successfully updated $RECORD_NAME to $CURRENT_IP"
    else
        echo "$(date): ERROR updating $RECORD_NAME: $RESPONSE"
        ALL_SUCCEEDED=false
    fi
done

# Only cache on full success, so a partial failure retries everything.
if [ "$ALL_SUCCEEDED" == "true" ]; then
    echo "$CURRENT_IP" > "$LAST_IP_FILE"
else
    echo "$(date): One or more updates failed, not caching IP so next run retries all records."
    exit 1
fi
