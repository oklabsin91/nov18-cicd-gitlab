#!/bin/bash

set -Eeuo pipefail

echo "========================================"
echo "         OKLABS APPLICATION"
echo "========================================"

# ========================================
# 1. READ ENVIRONMENT VARIABLES
# ========================================

: "${APP_ENV:?ERROR: APP_ENV is missing}"
: "${FQDN:?ERROR: FQDN is missing}"
: "${LETSENCRYPT_EMAIL:?ERROR: LETSENCRYPT_EMAIL is missing}"

echo "Environment: $APP_ENV"
echo "FQDN: $FQDN"
echo "Email: $LETSENCRYPT_EMAIL"

echo "Environment variables loaded successfully."

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

echo "Enabling Apache modules..."

a2enmod ssl rewrite headers

# ========================================
# 4. GENERATE TEMPORARY HTTP CONFIG
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
# 5. START TEMPORARY APACHE
# ========================================

echo "Starting temporary Apache HTTP server..."

apache2ctl configtest

apache2ctl -D FOREGROUND &
APACHE_PID=$!

# Handle Docker stop signals
cleanup() {
    echo "Stopping OKLABS application..."

    kill -TERM "$APACHE_PID" 2>/dev/null || true
    wait "$APACHE_PID" 2>/dev/null || true

    exit 0
}

trap cleanup TERM INT

# Wait for Apache
APACHE_READY=false

for i in {1..30}; do

    if curl -fsS http://127.0.0.1/ >/dev/null 2>&1; then
        APACHE_READY=true
        break
    fi

    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "ERROR: Apache failed to start"
        exit 1
    fi

    sleep 1

done

if [[ "$APACHE_READY" != true ]]; then
    echo "ERROR: Apache HTTP server did not become ready"
    exit 1
fi

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

    if [[ ! -f "$CERT_PATH" || ! -f "$KEY_PATH" ]]; then
        echo "ERROR: SSL certificate generation failed"
        exit 1
    fi

    echo "SSL certificate successfully generated!"

fi

# ========================================
# 7. GENERATE APACHE HTTPS CONFIGURATION
# ========================================

echo "Generating Apache HTTP/HTTPS VirtualHosts..."

cat > /etc/apache2/sites-available/000-default.conf <<EOF

# ========================================
# HTTP VIRTUAL HOST
# ========================================

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

    RewriteEngine On

    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://$FQDN%{REQUEST_URI} [R=301,L]

</VirtualHost>


# ========================================
# HTTPS VIRTUAL HOST
# ========================================

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
# 8. VALIDATE AND RELOAD APACHE
# ========================================

echo "Validating Apache configuration..."

apache2ctl configtest

echo "Reloading Apache..."

apache2ctl graceful

echo "HTTPS configuration enabled!"

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

RENEWAL_PID=$!

# ========================================
# 10. APPLICATION READY
# ========================================

echo "========================================"
echo "       OKLABS APPLICATION READY"
echo "========================================"

echo "Environment : $APP_ENV"
echo "FQDN        : $FQDN"
echo "HTTP        : Redirecting to HTTPS"
echo "HTTPS       : https://$FQDN"
echo "SSL         : Enabled"
echo "========================================"

# ========================================
# 11. KEEP CONTAINER RUNNING
# ========================================

# Wait for Apache and propagate shutdown signals.
wait "$APACHE_PID"

