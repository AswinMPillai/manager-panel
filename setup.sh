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
sudo apt install -y nginx python3 python3-venv python3-pip php php-fpm php-mysqli php-mbstring php-zip php-gd php-json php-curl \
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
    python3 -m venv myenv
    source myenv/bin/activate
    pip install --upgrade pip
    
    # Check if requirements.txt exists
    if [[ -f requirements.txt ]]; then
        pip install -r requirements.txt
    else
        echo "⚠️  requirements.txt not found, skipping pip install"
    fi
    
    deactivate
    echo "✅ Crontab Editor installed"
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
if [[ -d /var/www/html/crontab-editor ]]; then
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
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL
    sudo systemctl enable crontab-manager
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
echo "  1. Configure Nginx reverse proxy for:"
echo "     - Manager Frontend: /var/www/html/manager"
echo "     - FileBrowser: http://127.0.0.1:8082"
echo "     - phpMyAdmin: /usr/share/phpmyadmin"
echo "     - Crontab Editor: http://127.0.0.1:8765"
echo "  2. Setup SSL certificate with certbot"
echo "  3. Configure domain and firewall rules"
echo ""
echo "🔑 FileBrowser Admin Credentials:"
echo "   Username: admin"
echo "   Password: (the password you just set)"
echo ""
echo "═══════════════════════════════════════════"