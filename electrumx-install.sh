#!/bin/bash

# Electrum Server Setup Script for Debian
# Configures Electrum server with Let's Encrypt SSL, using an existing Bitcoin node
# Accepts connections on port 443

# Exit on error
set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to prompt for user input with validation
prompt_for_input() {
    local prompt="$1"
    local var_name="$2"
    local value
    read -p "$prompt" value
    if [ -z "$value" ]; then
        echo "Error: Input cannot be empty."
        exit 1
    fi
    eval "$var_name='$value'"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root (use sudo)."
    exit 1
fi

# Update package lists
echo "Updating package lists..."
apt-get update

# Install required dependencies
echo "Installing dependencies..."
apt-get install -y python3 python3-pip python3-dev build-essential libssl-dev certbot python3-certbot-nginx git

# Prompt for public DNS name
prompt_for_input "Enter your public DNS name (e.g., electrum.example.com): " PUBLIC_DNS

# Prompt for Bitcoin RPC credentials
prompt_for_input "Enter Bitcoin RPC username: " BITCOIN_RPC_USER
prompt_for_input "Enter Bitcoin RPC password: " BITCOIN_RPC_PASSWORD
prompt_for_input "Enter Bitcoin RPC host (default: 127.0.0.1): " BITCOIN_RPC_HOST
BITCOIN_RPC_HOST=${BITCOIN_RPC_HOST:-127.0.0.1}
prompt_for_input "Enter Bitcoin RPC port (default: 8332): " BITCOIN_RPC_PORT
BITCOIN_RPC_PORT=${BITCOIN_RPC_PORT:-8332}

# Install Electrum Server (ElectrumX)
echo "Installing ElectrumX..."
pip3 install electrumx

# Create ElectrumX configuration directory
mkdir -p /etc/electrumx
CONFIG_FILE="/etc/electrumx/electrumx.conf"

# Write ElectrumX configuration
echo "Creating ElectrumX configuration..."
cat > $CONFIG_FILE <<EOL
# ElectrumX Configuration
DB_DIRECTORY = /var/lib/electrumx
DAEMON_URL = http://$BITCOIN_RPC_USER:$BITCOIN_RPC_PASSWORD@$BITCOIN_RPC_HOST:$BITCOIN_RPC_PORT
COIN = Bitcoin
NET = mainnet
SERVICES = tcp://0.0.0.0:50001,ssl://0.0.0.0:443
SSL_CERTFILE = /etc/letsencrypt/live/$PUBLIC_DNS/fullchain.pem
SSL_KEYFILE = /etc/letsencrypt/live/$PUBLIC_DNS/privkey.pem
REPORT_SERVICES = tcp://$PUBLIC_DNS:50001,ssl://$PUBLIC_DNS:443
PEER_DISCOVERY = on
PEER_ANNOUNCE = on
REQUEST_TIMEOUT = 30
MAX_SESSIONS = 20000
MAX_SEND=10000000
LOG_LEVEL = info
EOL

# Create data directory and set permissions
mkdir -p /var/lib/electrumx
useradd -m -s /bin/false electrumx || echo "User electrumx already exists."
chown -R electrumx:electrumx /var/lib/electrumx
chmod 750 /var/lib/electrumx

# Install Nginx for Let's Encrypt validation
if ! command_exists nginx; then
    echo "Installing Nginx..."
    apt-get install -y nginx
fi

# Obtain Let's Encrypt certificate
echo "Obtaining Let's Encrypt certificate..."
certbot certonly --nginx -d $PUBLIC_DNS --non-interactive --agree-tos --email admin@$PUBLIC_DNS || {
    echo "Failed to obtain Let's Encrypt certificate. Please check your DNS settings and try again."
    exit 1
}

# Create systemd service for ElectrumX
echo "Creating ElectrumX systemd service..."
cat > /etc/systemd/system/electrumx.service <<EOL
[Unit]
Description=ElectrumX Server
After=network.target

[Service]
User=electrumx
Group=electrumx
ExecStart=/usr/local/bin/electrumx_server
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/etc/electrumx/electrumx.conf
WorkingDirectory=/var/lib/electrumx
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable electrumx
systemctl start electrumx

# Open firewall ports (if ufw is installed)
if command_exists ufw; then
    echo "Configuring firewall..."
    ufw allow 443/tcp
    ufw allow 50001/tcp
    echo "Firewall rules updated."
fi

# Display completion message
echo "ElectrumX server setup complete!"
echo "Server is running and accessible at:"
echo "- TCP: $PUBLIC_DNS:50001"
echo "- SSL: $PUBLIC_DNS:443"
echo "Ensure your Bitcoin node is fully synced and running."
echo "You may need to configure your DNS to point $PUBLIC_DNS to this server's public IP."
