#!/bin/bash
set -e

# ===========================
# Manager Panel Complete Setup Script
# ===========================

# Ensure script is running from its directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Starting Manager Panel Full Setup..."

# ---------------------------
# 1️⃣ Ask for domain name and email
# ---------------------------
read -p "Enter your domain (e.g., manager.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "❌ Domain cannot be empty. Exiting."
    exit 1
fi

read -p "Enter your email for SSL certificate (Let's Encrypt): " EMAIL
if [[ -z "$EMAIL" ]]; then
    echo "❌ Email cannot be empty. Exiting."
    exit 1
fi

# ---------------------------
# 2️⃣ Update system & install dependencies
# ---------------------------
sudo apt update && sudo apt upgrade -y
sudo apt install -y nginx python3 python3-venv python3-pip php8.2-fpm unzip curl certbot python3-certbot-nginx \
                    redis-server gunicorn unzip wget zip

# Enable Redis
sudo systemctl enable --now redis-server

# ---------------------------
# 3️⃣ Install FileBrowser
# ---------------------------
echo "📂 Installing FileBrowser..."
sudo mkdir -p /opt/filebrowser
cd /opt/filebrowser
sudo curl -fsSL https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz -o filebrowser.tar.gz
sudo tar -xzf filebrowser.tar.gz
sudo rm filebrowser.tar.gz
sudo chmod +x /opt/filebrowser/filebrowser
sudo mkdir -p /opt/filebrowser/data
sudo touch /opt/filebrowser/data/filebrowser.db
sudo chown -R www-data:www-data /opt/filebrowser

# ---------------------------
# 4️⃣ Setup Crontab Editor
# ---------------------------
echo "🕒 Setting up Crontab Editor..."
sudo rm -rf /var/www/html/crontab-editor
sudo mkdir -p /var/www/html/crontab-editor
sudo cp -r "$SCRIPT_DIR/crontab-editor/"* /var/www/html/crontab-editor/
cd /var/www/html/crontab-editor
python3 -m venv myenv
source myenv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# ---------------------------
# 5️⃣ Deploy Manager Frontend
# ---------------------------
echo "🌐 Deploying frontend manager..."
sudo rm -rf /var/www/html/manager
sudo mkdir -p /var/www/html/manager
sudo cp -r "$SCRIPT_DIR/manager/"* /var/www/html/manager
sudo chown -R www-data:www-data /var/www/html/manager
sudo chmod -R 775 /var/www/html/manager

# ---------------------------
# 6️⃣ Install phpMyAdmin
# ---------------------------
echo "💾 Installing phpMyAdmin..."
sudo apt install -y phpmyadmin
sudo mkdir -p /usr/share/phpmyadmin/tmp
sudo chmod 777 /usr/share/phpmyadmin/tmp
sudo chown www-data:www-data /usr/share/phpmyadmin/tmp

# ---------------------------
# 7️⃣ Configure Nginx for domain 
# ---------------------------
echo "🖥 Configuring Nginx for $DOMAIN..."
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOL
server {
    listen 443 ssl http2;
    server_name $DOMAIN;
    root /var/www/html;
    index index.html index.php;
    client_max_body_size 100M;

    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # --------------------------
    # FileBrowser - HIGHEST PRIORITY (before any PHP processing)
    # --------------------------
    location ~ ^/manager/files/login {
        return 302 /manager/files/;
    }
    location /manager/files/ {
        auth_basic "Manager";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:8082/manager/files/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Remote-User $remote_user;
        proxy_redirect off;
        proxy_buffering off;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # FileBrowser static assets
    location /static/ {
        proxy_pass http://127.0.0.1:8082/static/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
    }

    # --------------------------
    # /manager local files (NOT FileBrowser)
    # --------------------------
    location /manager/ {
        auth_basic "Manager";
        auth_basic_user_file /etc/nginx/.htpasswd;
        root /var/www/html;
        index index.html index.php;
        try_files $uri $uri/ =404;

        # PHP for /manager local files ONLY (exclude /manager/files/)
        location ~ ^/manager/(?!files/).*\.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
        }
    }

    # --------------------------
    # phpMyAdmin
    # --------------------------
    location /manager/db/ {
        auth_basic "Manager";
        auth_basic_user_file /etc/nginx/.htpasswd;
        alias /usr/share/phpmyadmin/;
        index index.php index.html index.htm;

        location ~ ^/manager/db/(.+\.php)$ {
            alias /usr/share/phpmyadmin/$1;
            fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $request_filename;
            fastcgi_param REMOTE_USER $remote_user;
        }

        location ~* ^/manager/db/(.+\.(?:jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            alias /usr/share/phpmyadmin/$1;
        }
    }

    # --------------------------
    # Crontab Manager
    # --------------------------
    location /manager/crontab/ {
        auth_basic "Manager";
        auth_basic_user_file /etc/nginx/.htpasswd;
        proxy_pass http://127.0.0.1:8765/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Script-Name /manager/crontab;
        proxy_set_header X-Authenticated-User $remote_user;
        proxy_redirect off;
    }

    # --------------------------
    # No general PHP processing - this server is for FileBrowser only
    # Other domains handle PHP processing separately
    # --------------------------

    # --------------------------
    # Logging
    # --------------------------
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;

    # SSL settings...
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_ciphers HIGH:!aNULL:!MD5;
}
EOL

sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx

# ---------------------------
# 8️⃣ Setup systemd services
# ---------------------------

# FileBrowser service
sudo tee /etc/systemd/system/filebrowser.service > /dev/null <<EOL
[Unit]
Description=FileBrowser Service
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=/home
ExecStart=/opt/filebrowser/filebrowser -r=/home -d=/opt/filebrowser/data/filebrowser.db -a=127.0.0.1 -p=8082 --baseurl=/manager/files
Restart=always
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Crontab Editor service
sudo tee /etc/systemd/system/crontab-manager.service > /dev/null <<EOL
[Unit]
Description=Gunicorn Service for Crontab Manager
After=network.target redis.service

[Service]
User=root
Group=root
WorkingDirectory=/var/www/html/crontab-editor
ExecStart=/var/www/html/crontab-editor/myenv/bin/gunicorn --workers 3 --bind 0.0.0.0:8765 --forwarded-allow-ips=* wsgi:app
Restart=always

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable --now filebrowser
sudo systemctl enable --now crontab-manager

# ---------------------------
# 1️⃣0️⃣ Final reload Nginx
# ---------------------------
sudo nginx -t
sudo systemctl reload nginx

echo "✅ Manager Panel setup complete!"
echo "Visit: https://$DOMAIN/manager"
echo "phpMyAdmin: https://$DOMAIN/manager/db/"
echo "Crontab Editor: https://$DOMAIN/manager/crontab/"
