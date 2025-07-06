#!/bin/bash
# Pi 5 Travel Router Restore Script
# This script will restore your Pi 5 to a working travel router configuration

set -e

echo "🔧 Pi 5 Travel Router Restore Script"
echo "===================================="
echo

# Function to check current system status
check_system_status() {
    echo "📊 Checking current system status..."
    
    # Check if we're running on Pi 5
    if [[ $(uname -m) != "aarch64" ]]; then
        echo "⚠️  Warning: This doesn't appear to be a Pi 5"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # Check what's currently installed
    echo "🔍 Current system status:"
    
    # Check for problematic services
    if systemctl is-active --quiet pihole-FTL 2>/dev/null; then
        echo "❌ PiHole is active (this may be causing conflicts)"
        PIHOLE_ACTIVE=true
    else
        echo "✅ PiHole is not active"
        PIHOLE_ACTIVE=false
    fi
    
    # Check for our services
    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        echo "📡 dnsmasq is active"
        DNSMASQ_ACTIVE=true
    else
        echo "⚪ dnsmasq is not active"
        DNSMASQ_ACTIVE=false
    fi
    
    if systemctl is-active --quiet hostapd 2>/dev/null; then
        echo "📶 hostapd is active"
        HOSTAPD_ACTIVE=true
    else
        echo "⚪ hostapd is not active"
        HOSTAPD_ACTIVE=false
    fi
    
    if command -v wg &> /dev/null; then
        echo "🔐 WireGuard is installed"
        WG_INSTALLED=true
    else
        echo "⚪ WireGuard is not installed"
        WG_INSTALLED=false
    fi
    
    if command -v protonvpn-cli &> /dev/null; then
        echo "🛡️  ProtonVPN CLI is installed"
        PROTON_INSTALLED=true
    else
        echo "⚪ ProtonVPN CLI is not installed"
        PROTON_INSTALLED=false
    fi
    
    echo
}

# Function to ask for configuration details
gather_config_info() {
    echo "📋 Configuration Information Needed"
    echo "=================================="
    echo
    
    echo "Please provide the following information from your Pi 5:"
    echo
    
    # Ask for summary file location
    read -p "📄 Path to your configuration summary file on Pi 5: " SUMMARY_FILE
    
    if [ -f "$SUMMARY_FILE" ]; then
        echo "✅ Found summary file"
        echo "📖 Contents:"
        echo "----------------------------------------"
        cat "$SUMMARY_FILE"
        echo "----------------------------------------"
        echo
    else
        echo "⚠️  Summary file not found at $SUMMARY_FILE"
        echo "Please provide the configuration details manually:"
        echo
        
        # Manual configuration gathering
        read -p "🌐 WiFi Network Name (SSID) you want to broadcast: " WIFI_SSID
        read -p "🔑 WiFi Password: " WIFI_PASSWORD
        read -p "📡 WiFi Channel (1-11, default 7): " WIFI_CHANNEL
        WIFI_CHANNEL=${WIFI_CHANNEL:-7}
        
        read -p "🔌 Ethernet interface name (default eth0): " ETH_INTERFACE
        ETH_INTERFACE=${ETH_INTERFACE:-eth0}
        
        read -p "📶 WiFi interface name (default wlan0): " WIFI_INTERFACE
        WIFI_INTERFACE=${WIFI_INTERFACE:-wlan0}
        
        read -p "🌍 IP range for your network (default 192.168.4.0/24): " IP_RANGE
        IP_RANGE=${IP_RANGE:-192.168.4.0/24}
        
        read -p "🔐 Do you have ProtonVPN credentials? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            SETUP_PROTONVPN=true
            echo "📝 You'll need to run 'protonvpn-cli login' after setup"
        else
            SETUP_PROTONVPN=false
        fi
    fi
    
    echo
    read -p "🚀 Ready to proceed with restoration? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Setup cancelled"
        exit 1
    fi
}

# Function to clean up conflicting services
cleanup_conflicts() {
    echo "🧹 Cleaning up conflicting configurations..."
    
    if [ "$PIHOLE_ACTIVE" = true ]; then
        echo "🛑 Stopping PiHole services..."
        sudo systemctl stop pihole-FTL
        sudo systemctl disable pihole-FTL
        
        # Ask if they want to remove PiHole completely
        read -p "🗑️  Remove PiHole completely? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "🗑️  Removing PiHole..."
            sudo apt remove --purge pihole-FTL -y
            sudo rm -rf /etc/pihole
            sudo rm -rf /var/log/pihole
        fi
    fi
    
    # Stop conflicting services
    sudo systemctl stop dnsmasq hostapd 2>/dev/null || true
    
    # Backup existing configs
    echo "💾 Backing up existing configurations..."
    sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    sudo cp /etc/hostapd/hostapd.conf /etc/hostapd/hostapd.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    sudo cp /etc/dhcpcd.conf /etc/dhcpcd.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
}

# Function to install required packages
install_packages() {
    echo "📦 Installing required packages..."
    
    sudo apt update
    sudo apt install -y \
        hostapd \
        dnsmasq \
        iptables-persistent \
        wireguard \
        resolvconf \
        curl \
        wget \
        speedtest-cli
    
    if [ "$SETUP_PROTONVPN" = true ]; then
        echo "🔐 Installing ProtonVPN..."
        if ! command -v protonvpn-cli &> /dev/null; then
            wget -O /tmp/protonvpn-stable-release_1.0.3-2_all.deb \
                https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.3-2_all.deb
            sudo dpkg -i /tmp/protonvpn-stable-release_1.0.3-2_all.deb
            sudo apt update
            sudo apt install -y protonvpn-cli
        fi
    fi
}

# Function to configure the system
configure_system() {
    echo "⚙️  Configuring system..."
    
    # Use defaults if manual config wasn't provided
    WIFI_SSID=${WIFI_SSID:-"Pi5-TravelRouter"}
    WIFI_PASSWORD=${WIFI_PASSWORD:-"travelrouter123"}
    WIFI_CHANNEL=${WIFI_CHANNEL:-7}
    ETH_INTERFACE=${ETH_INTERFACE:-eth0}
    WIFI_INTERFACE=${WIFI_INTERFACE:-wlan0}
    IP_RANGE=${IP_RANGE:-192.168.4.0/24}
    
    # Configure hostapd
    echo "📶 Configuring hostapd..."
    sudo tee /etc/hostapd/hostapd.conf > /dev/null <<EOF
interface=$WIFI_INTERFACE
driver=nl80211
ssid=$WIFI_SSID
hw_mode=g
channel=$WIFI_CHANNEL
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$WIFI_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF
    
    # Configure dnsmasq
    echo "📡 Configuring dnsmasq..."
    sudo tee /etc/dnsmasq.conf > /dev/null <<EOF
interface=$WIFI_INTERFACE
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
domain=wlan
address=/gw.wlan/192.168.4.1
EOF
    
    # Configure dhcpcd
    echo "🔌 Configuring dhcpcd..."
    sudo tee -a /etc/dhcpcd.conf > /dev/null <<EOF

# Travel Router Configuration
interface $WIFI_INTERFACE
    static ip_address=192.168.4.1/24
    nohook wpa_supplicant
EOF
    
    # Configure IP forwarding
    echo "🔀 Enabling IP forwarding..."
    echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
    
    # Configure iptables
    echo "🛡️  Configuring iptables..."
    sudo iptables -t nat -A POSTROUTING -o $ETH_INTERFACE -j MASQUERADE
    sudo iptables -A FORWARD -i $ETH_INTERFACE -o $WIFI_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A FORWARD -i $WIFI_INTERFACE -o $ETH_INTERFACE -j ACCEPT
    
    # Save iptables rules
    sudo sh -c "iptables-save > /etc/iptables.ipv4.nat"
    
    # Enable services
    echo "🔧 Enabling services..."
    sudo systemctl enable hostapd
    sudo systemctl enable dnsmasq
    sudo systemctl enable ssh
}

# Function to create management scripts
create_management_scripts() {
    echo "📜 Creating management scripts..."
    
    # Status check script
    cat > ~/travel-router-status.sh << 'EOF'
#!/bin/bash
echo "📊 Pi 5 Travel Router Status"
echo "=========================="
echo
echo "🔌 Network Interfaces:"
ip addr show | grep -E "wlan0|eth0" -A 5
echo
echo "📡 Services:"
systemctl is-active hostapd && echo "✅ hostapd: active" || echo "❌ hostapd: inactive"
systemctl is-active dnsmasq && echo "✅ dnsmasq: active" || echo "❌ dnsmasq: inactive"
echo
echo "🔐 VPN Status:"
if command -v protonvpn-cli &> /dev/null; then
    protonvpn-cli status
else
    echo "❌ ProtonVPN not installed"
fi
echo
echo "📶 WiFi Clients:"
sudo iw dev wlan0 station dump | grep Station | wc -l | xargs echo "Connected devices:"
EOF
    
    # Quick restart script
    cat > ~/travel-router-restart.sh << 'EOF'
#!/bin/bash
echo "🔄 Restarting Travel Router services..."
sudo systemctl restart hostapd
sudo systemctl restart dnsmasq
sudo systemctl restart dhcpcd
echo "✅ Services restarted"
EOF
    
    # Make scripts executable
    chmod +x ~/travel-router-status.sh
    chmod +x ~/travel-router-restart.sh
}

# Main execution
main() {
    echo "🚀 Starting Pi 5 Travel Router Restoration..."
    echo
    
    check_system_status
    gather_config_info
    cleanup_conflicts
    install_packages
    configure_system
    create_management_scripts
    
    echo
    echo "🎉 Pi 5 Travel Router Restoration Complete!"
    echo "=========================================="
    echo
    echo "📋 Next Steps:"
    echo "1. Reboot your Pi 5: sudo reboot"
    if [ "$SETUP_PROTONVPN" = true ]; then
        echo "2. Configure ProtonVPN: protonvpn-cli login"
    fi
    echo "3. Check status: ./travel-router-status.sh"
    echo "4. Restart services if needed: ./travel-router-restart.sh"
    echo
    echo "📶 Your Pi 5 will broadcast: $WIFI_SSID"
    echo "🔑 Password: $WIFI_PASSWORD"
    echo "🌐 Gateway IP: 192.168.4.1"
    echo
    echo "🔧 Troubleshooting:"
    echo "- Check logs: journalctl -u hostapd -f"
    echo "- Check logs: journalctl -u dnsmasq -f"
    echo "- Manual restart: ./travel-router-restart.sh"
}

# Run main function
main "$@"