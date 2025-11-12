#!/bin/bash
set -e

# ===========================
# Manager Panel Setup Script
# ===========================

# Ensure paths are correct
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🚀 Starting Manager Panel Setup..."

# 1️⃣ Ask for domain name
read -p "Enter your domain (e.g., manager.example.com): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
    echo "❌ Domain cannot be empty. Exiting."
    exit 1
fi

# 2️⃣ Ask for email for SSL
read -p "Enter your email for SSL certificate (Let's Encrypt): " EMAIL
if [[ -z "$EMAIL" ]]; then
    echo "❌ Email cannot be empty. Exiting."
    exit 1
fi

# 3️⃣ Update & install dependencies
sudo apt update && sudo apt upgrade -y
sudo apt install -y nginx python3 python3-venv python3-pip php8.2-fpm unzip curl certbot python3-certbot-nginx

# 4️⃣ Install FileBrowser
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

# 5️⃣ Setup Crontab Editor
echo "🕒 Setting up Crontab Editor..."
sudo rm -rf /var/www/html/crontab-editor
sudo mkdir -p /var/www/html/crontab-editor
sudo cp -r "$SCRIPT_DIR/crontab-editor/"* /var/www/html/crontab-editor/
cd /var/www/html/crontab-editor
python3 -m venv myenv
source myenv/bin/activate
pip install -r requirements.txt
deactivate

# 6️⃣ Deploy frontend manager
echo "🌐 Deploying frontend manager..."
sudo rm -rf /var/www/html/manager
sudo mkdir -p /var/www/html/manager
sudo cp -r "$SCRIPT_DIR/manager/"* /var/www/html/manager
sudo chown -R www-data:www-data /var/www/html/manager
sudo chmod -R 775 /var/www/html/manager

# 7️⃣ Install phpMyAdmin
echo "💾 Installing phpMyAdmin..."
sudo apt install -y phpmyadmin

# 8️⃣ Configure Nginx
echo "🖥 Configuring Nginx..."
sudo sed "s/{{DOMAIN}}/$DOMAIN/g" "$SCRIPT_DIR/nginx/manager.nginx.template" | sudo tee /etc/nginx/sites-available/$DOMAIN
sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# 9️⃣ Setup systemd services

# FileBrowser
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

# Crontab Editor
sudo tee /etc/systemd/system/crontab-manager.service > /dev/null <<EOL
[Unit]
Description=Gunicorn Service for Crontab Manager
After=network.target

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

# 🔐 Setup SSL via Certbot
echo "🔐 Setting up SSL for $DOMAIN..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "✅ Manager panel setup complete!"
echo "Visit: https://$DOMAIN/manager"
