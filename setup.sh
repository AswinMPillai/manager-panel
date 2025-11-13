#!/bin/bash
set -e

# ===========================
# Manager Panel Setup Script
# ===========================

# Ensure script is running from its directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Starting Manager Panel Installation..."

# ---------------------------
# 1️⃣ Update system & install dependencies
# ---------------------------
echo "📦 Installing dependencies..."
sudo apt update && sudo apt upgrade -y

# Detect installed PHP version or install default
if command -v php &> /dev/null; then
    PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
    echo "✓ PHP $PHP_VERSION detected"
else
    PHP_VERSION="8.2"
    echo "→ Installing PHP $PHP_VERSION"
fi

# Install packages with specific PHP version
sudo apt install -y nginx python3 python3-venv python3-pip \
                    php${PHP_VERSION} php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql php${PHP_VERSION}-mbstring \
                    php${PHP_VERSION}-zip php${PHP_VERSION}-gd php${PHP_VERSION}-curl php${PHP_VERSION}-xml \
                    redis-server gunicorn unzip wget zip curl

# Enable Redis
sudo systemctl enable --now redis-server

# ---------------------------
# 2️⃣ Install FileBrowser
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

# Initialize FileBrowser with default credentials
sudo /opt/filebrowser/filebrowser config init -d /opt/filebrowser/data/filebrowser.db
sudo /opt/filebrowser/filebrowser config set -d /opt/filebrowser/data/filebrowser.db --address 127.0.0.1 --port 8082 --baseurl /manager/files --root /home

# Ask for admin password
echo ""
echo "🔐 Setting FileBrowser admin password..."
read -sp "Enter password for FileBrowser admin user: " FB_PASSWORD
echo ""
read -sp "Confirm password: " FB_PASSWORD_CONFIRM
echo ""

if [[ "$FB_PASSWORD" != "$FB_PASSWORD_CONFIRM" ]]; then
    echo "❌ Passwords do not match. Exiting."
    exit 1
fi

if [[ -z "$FB_PASSWORD" ]]; then
    echo "❌ Password cannot be empty. Exiting."
    exit 1
fi

# Create admin user with password
sudo /opt/filebrowser/filebrowser users add admin "$FB_PASSWORD" -d /opt/filebrowser/data/filebrowser.db --perm.admin

sudo chown -R www-data:www-data /opt/filebrowser

echo "✅ FileBrowser installed with admin user"

# ---------------------------
# 3️⃣ Setup Crontab Editor
# ---------------------------
echo "🕒 Setting up Crontab Editor..."
sudo rm -rf /var/www/html/crontab-editor
sudo mkdir -p /var/www/html/crontab-editor

# Check if crontab-editor directory exists in script directory
if [[ -d "$SCRIPT_DIR/crontab-editor" ]]; then
    sudo cp -r "$SCRIPT_DIR/crontab-editor/"* /var/www/html/crontab-editor/
    cd /var/www/html/crontab-editor
    
    # Create virtual environment
    echo "  → Creating Python virtual environment..."
    sudo python3 -m venv myenv
    
    # Install packages - MUST install gunicorn first before requirements.txt
    echo "  → Installing Python packages..."
    sudo myenv/bin/pip install --upgrade pip
    sudo myenv/bin/pip install gunicorn Flask redis
    
    # Install additional requirements if available
    if [[ -f requirements.txt ]]; then
        echo "  → Installing from requirements.txt..."
        sudo myenv/bin/pip install -r requirements.txt
    fi
    
    # Ensure proper permissions
    sudo chown -R root:root /var/www/html/crontab-editor
    sudo chmod +x myenv/bin/*
    
    # Verify installation
    if myenv/bin/pip list | grep -q gunicorn; then
        echo "✅ Crontab Editor installed successfully"
    else
        echo "❌ Error: gunicorn installation failed"
        exit 1
    fi
else
    echo "⚠️  crontab-editor directory not found in $SCRIPT_DIR, skipping..."
fi

# ---------------------------
# 4️⃣ Deploy Manager Frontend
# ---------------------------
echo "🌐 Deploying frontend manager..."
sudo rm -rf /var/www/html/manager
sudo mkdir -p /var/www/html/manager

# Check if manager directory exists in script directory
if [[ -d "$SCRIPT_DIR/manager" ]]; then
    sudo cp -r "$SCRIPT_DIR/manager/"* /var/www/html/manager/
    sudo chown -R www-data:www-data /var/www/html/manager
    sudo chmod -R 775 /var/www/html/manager
    echo "✅ Manager frontend deployed"
else
    echo "⚠️  manager directory not found in $SCRIPT_DIR, skipping..."
fi

# ---------------------------
# 5️⃣ Install phpMyAdmin
# ---------------------------
echo "💾 Installing phpMyAdmin..."
sudo apt install -y phpmyadmin

# Create tmp directory for phpMyAdmin
sudo mkdir -p /usr/share/phpmyadmin/tmp
sudo chmod 777 /usr/share/phpmyadmin/tmp
sudo chown www-data:www-data /usr/share/phpmyadmin/tmp

echo "✅ phpMyAdmin installed"

# ---------------------------
# 6️⃣ Setup systemd services
# ---------------------------
echo "⚙️  Setting up systemd services..."

# FileBrowser service
sudo tee /etc/systemd/system/filebrowser.service > /dev/null <<EOL
[Unit]
Description=FileBrowser Service
After=network.target

[Service]
User=www-data
Group=www-data
WorkingDirectory=/home
ExecStart=/opt/filebrowser/filebrowser -d /opt/filebrowser/data/filebrowser.db
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Crontab Editor service (only if directory exists)
if [[ -d /var/www/html/crontab-editor ]] && [[ -f /var/www/html/crontab-editor/myenv/bin/gunicorn ]]; then
    sudo tee /etc/systemd/system/crontab-manager.service > /dev/null <<EOL
[Unit]
Description=Gunicorn Service for Crontab Manager
After=network.target redis.service

[Service]
User=root
Group=root
WorkingDirectory=/var/www/html/crontab-editor
Environment="PATH=/var/www/html/crontab-editor/myenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/var/www/html/crontab-editor/myenv/bin/gunicorn --workers 3 --bind 0.0.0.0:8765 --forwarded-allow-ips=* wsgi:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL
    sudo systemctl enable crontab-manager
    echo "✅ Crontab Manager service created"
else
    echo "⚠️  Gunicorn not found, skipping crontab-manager service"
fi

# Reload systemd and start services
sudo systemctl daemon-reload
sudo systemctl enable filebrowser
sudo systemctl start filebrowser

if [[ -f /etc/systemd/system/crontab-manager.service ]]; then
    sudo systemctl start crontab-manager
fi

# ---------------------------
# 7️⃣ Display service status
# ---------------------------
echo ""
echo "═══════════════════════════════════════════"
echo "✅ Manager Panel Setup Complete!"
echo "═══════════════════════════════════════════"
echo ""
echo "📋 Service Status:"
sudo systemctl status filebrowser --no-pager -l | head -n 3
if [[ -f /etc/systemd/system/crontab-manager.service ]]; then
    sudo systemctl status crontab-manager --no-pager -l | head -n 3
fi
echo ""
echo "📝 Next Steps:"
echo "  1. Configure Nginx reverse proxy"
echo "  2. Setup SSL certificate with certbot"
echo "  3. Configure domain and firewall rules"
echo ""
echo "🔑 FileBrowser Admin Credentials:"
echo "   Username: admin"
echo "   Password: (the password you just set)"
echo ""
echo "═══════════════════════════════════════════"
echo ""

# ---------------------------
# 8️⃣ Create Nginx configuration example
# ---------------------------
echo "📄 Creating Nginx configuration example..."
sudo tee /var/www/html/manager-nginx-example.conf > /dev/null <<'EOL'
# =========================================
# Manager Panel Nginx Configuration Example
# =========================================
# Copy this to: /etc/nginx/sites-available/manager-panel
# Enable with: sudo ln -s /etc/nginx/sites-available/manager-panel /etc/nginx/sites-enabled/
# Test config: sudo nginx -t
# Reload nginx: sudo systemctl reload nginx

server {
    listen 443 ssl http2;
    server_name your-domain.com;  # CHANGE THIS
    root /var/www/html;
    index index.html index.php;
    client_max_body_size 100M;

    # SSL certificates (Configure with certbot)
    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;  # CHANGE THIS
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;  # CHANGE THIS

    # --------------------------
    # FileBrowser - HIGHEST PRIORITY
    # --------------------------
    location /manager/files/ {
        proxy_pass http://127.0.0.1:8082/manager/files/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_redirect off;
        proxy_buffering off;
        
        # WebSocket support
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
    # Manager Frontend (local files)
    # --------------------------
    location /manager/ {
        root /var/www/html;
        index index.html index.php;
        try_files $uri $uri/ =404;
        
        # PHP processing for manager frontend (exclude /manager/files/)
        location ~ ^/manager/(?!files/).*\.php$ {
            include snippets/fastcgi-php.conf;
            fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;  # Adjust PHP version if needed
        }
    }

    # --------------------------
    # phpMyAdmin
    # --------------------------
    location /manager/db/ {
        alias /usr/share/phpmyadmin/;
        index index.php index.html index.htm;
        
        location ~ ^/manager/db/(.+\.php)$ {
            alias /usr/share/phpmyadmin/$1;
            fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;  # Adjust PHP version if needed
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME $request_filename;
        }
        
        location ~* ^/manager/db/(.+\.(?:jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            alias /usr/share/phpmyadmin/$1;
        }
    }

    # --------------------------
    # Crontab Manager
    # --------------------------
    location /manager/crontab/ {
        proxy_pass http://127.0.0.1:8765/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_set_header X-Script-Name /manager/crontab;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_redirect off;
    }

    # --------------------------
    # Logging
    # --------------------------
    access_log /var/log/nginx/manager_access.log;
    error_log /var/log/nginx/manager_error.log;

    # --------------------------
    # SSL Settings
    # --------------------------
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_ciphers HIGH:!aNULL:!MD5;
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name your-domain.com;  # CHANGE THIS
    return 301 https://$server_name$request_uri;
}
EOL

echo "✅ Nginx example configuration created at: /var/www/html/manager-nginx-example.conf"
echo ""
echo "📋 To use the Nginx configuration:"
echo "  1. Edit the example file and change 'your-domain.com' to your domain"
echo "  2. Adjust PHP-FPM socket path if needed (check with: ls /var/run/php/)"
echo "  3. Copy to Nginx sites: sudo cp /var/www/html/manager-nginx-example.conf /etc/nginx/sites-available/manager-panel"
echo "  4. Enable the site: sudo ln -s /etc/nginx/sites-available/manager-panel /etc/nginx/sites-enabled/"
echo "  5. Get SSL certificate: sudo certbot --nginx -d your-domain.com"
echo "  6. Test config: sudo nginx -t"
echo "  7. Reload Nginx: sudo systemctl reload nginx"
echo ""