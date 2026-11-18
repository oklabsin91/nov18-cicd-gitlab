
#!/bin/bash

set -Eeuo pipefail

echo "========================================"
echo "         OKLABS APPLICATION"
echo "========================================"

# ========================================
# 1. LOAD ENVIRONMENT FILE
# ========================================

ENV_FILE="/var/www/html/.env"

if [[ -f "$ENV_FILE" ]]; then
    echo "Loading environment variables from $ENV_FILE"

    set -a
    source "$ENV_FILE"
    set +a
else
    echo "WARNING: .env file not found!"
fi

APP_ENV="${APP_ENV:-production}"
FQDN="${FQDN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

echo "Environment: $APP_ENV"
echo "FQDN: $FQDN"
echo "Email: $LETSENCRYPT_EMAIL"

if [[ -z "$FQDN" || -z "$LETSENCRYPT_EMAIL" ]]; then
    echo "ERROR: FQDN or LETSENCRYPT_EMAIL is missing"
    exit 1
fi

# ========================================
# 2. SSL PATHS
# ========================================

CERT_PATH="/etc/letsencrypt/live/$FQDN/fullchain.pem"
KEY_PATH="/etc/letsencrypt/live/$FQDN/privkey.pem"

WEBROOT="/var/www/html"

mkdir -p "$WEBROOT/.well-known/acme-challenge"

# ========================================
# 3. ENABLE APACHE MODULES
# ========================================

a2enmod ssl rewrite headers

# ========================================
# 4. TEMPORARY HTTP CONFIGURATION
# ========================================

echo "Preparing temporary HTTP VirtualHost..."

cat > /etc/apache2/sites-available/000-default.conf <<EOF
<VirtualHost *:80>
    ServerName $FQDN
    DocumentRoot $WEBROOT

    Alias /.well-known/acme-challenge/ $WEBROOT/.well-known/acme-challenge/

    <Directory "$WEBROOT">
        AllowOverride All
        Require all granted
    </Directory>

    <Directory "$WEBROOT/.well-known/acme-challenge/">
        Require all granted
    </Directory>
</VirtualHost>
EOF

# ========================================
# 5. START APACHE TEMPORARILY
# ========================================

echo "Starting temporary Apache HTTP server..."

apache2ctl configtest

apache2ctl -D FOREGROUND &
APACHE_PID=$!

trap 'kill -TERM "$APACHE_PID" 2>/dev/null || true; wait "$APACHE_PID" || true; exit 0' TERM INT

for i in {1..30}; do

    if curl -fsS http://127.0.0.1/ >/dev/null; then
        break
    fi

    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "ERROR: Apache failed to start"
        exit 1
    fi

    sleep 1
done

# ========================================
# 6. CHECK AND REQUEST SSL CERTIFICATE
# ========================================

if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then

    echo "SSL certificate already exists for $FQDN"

else

    echo "SSL certificate not found!"
    echo "Requesting Let's Encrypt certificate..."

    certbot certonly \
        --webroot \
        --webroot-path "$WEBROOT" \
        --non-interactive \
        --agree-tos \
        --email "$LETSENCRYPT_EMAIL" \
        -d "$FQDN"

    echo "SSL certificate successfully generated!"

fi

# ========================================
# 7. GENERATE APACHE HTTPS CONFIGURATION
# ========================================

echo "Generating Apache HTTPS VirtualHost..."

cat > /etc/apache2/sites-available/000-default.conf <<EOF

<VirtualHost *:80>

    ServerName $FQDN
    DocumentRoot $WEBROOT

    Alias /.well-known/acme-challenge/ $WEBROOT/.well-known/acme-challenge/

    <Directory "$WEBROOT">
        AllowOverride All
        Require all granted
    </Directory>

    RewriteEngine On

    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://$FQDN%{REQUEST_URI} [R=301,L]

</VirtualHost>

<VirtualHost *:443>

    ServerName $FQDN
    DocumentRoot $WEBROOT

    SSLEngine on

    SSLCertificateFile $CERT_PATH
    SSLCertificateKeyFile $KEY_PATH

    <Directory "$WEBROOT">
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/ssl-access.log combined

</VirtualHost>

EOF

# ========================================
# 8. RELOAD APACHE
# ========================================

echo "Validating Apache configuration..."

apache2ctl configtest

echo "Enabling HTTPS..."

apache2ctl graceful

# ========================================
# 9. AUTOMATIC SSL RENEWAL
# ========================================

echo "Starting SSL renewal monitor..."

(
    while true; do
        sleep 12h

        echo "Checking Let's Encrypt certificate renewal..."

        if certbot renew --quiet; then
            echo "Certificate renewal check completed"
            apache2ctl graceful
        else
            echo "WARNING: Certificate renewal failed"
        fi

    done
) &

echo "========================================"
echo "       OKLABS APPLICATION READY"
echo "========================================"

echo "Environment: $APP_ENV"
echo "HTTP: Redirecting to HTTPS"
echo "HTTPS: https://$FQDN"
echo "SSL: Enabled"

wait "$APACHE_PID"

