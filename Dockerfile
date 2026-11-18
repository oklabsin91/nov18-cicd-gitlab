
FROM ubuntu/apache2:latest

WORKDIR /var/www/html

# Install Certbot and curl
RUN apt-get update && \
    apt-get install -y certbot curl && \
    rm -rf /var/lib/apt/lists/*

# Enable Apache modules
RUN a2enmod ssl rewrite headers

# Copy application
COPY index.html /var/www/html/

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh


RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && \
    chmod 755 /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["apache2ctl", "-D", "FOREGROUND"]

