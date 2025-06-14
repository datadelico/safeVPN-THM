#!/bin/bash
set -e

# Configuration
LOG_FILE="./backups/safevpn-thm.log"
BACKUP_DIR="./backups"
MAX_BACKUPS=5
VPN_INTERFACE="tun"
VPN_TIMEOUT=60
CLEANUP_DONE=0

# Function for logging
log() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Verify required tools
check_requirements() {
    log "DEBUG" "Checking required tools"
    
    local missing_tools=0
    for tool in openvpn iptables tc ip grep awk; do
        if ! command -v "$tool" &> /dev/null; then
            log "ERROR" "Required tool not found: $tool"
            missing_tools=1
        fi
    done
    
    if [ $missing_tools -eq 1 ]; then
        log "ERROR" "Please install missing tools and try again"
        exit 1
    fi
    
    log "DEBUG" "All required tools are available"
}

# Function to clean up and exit
cleanup() {
    # Prevent double execution of cleanup
    if [ $CLEANUP_DONE -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1
    echo -e "\n\nCleaning up before exit...\n"
    log "INFO" "Attempting to restore previous iptables rules"
    if [ -f "$LATEST_BACKUP" ]; then
        iptables-restore < "$LATEST_BACKUP"
        log "INFO" "Previous rules restored"
    else
        log "WARN" "No backup found to restore"
    fi
    
    log "INFO" "Stopping OpenVPN..."
    if pgrep openvpn > /dev/null; then
        # Try to close gracefully first
        killall -15 openvpn 2>/dev/null || true
        # Wait up to 5 seconds
        for i in {1..5}; do
            if ! pgrep openvpn > /dev/null; then
                log "INFO" "OpenVPN stopped successfully"
                break
            fi
            sleep 1
        done
        # If still running, force close
        if pgrep openvpn > /dev/null; then
            log "WARN" "Failed to stop OpenVPN gracefully, sending SIGKILL"
            killall -9 openvpn 2>/dev/null || true
            log "INFO" "OpenVPN stopped"
        fi
    else
        log "INFO" "OpenVPN is not running"
    fi
    
    # Remove tc rules when disconnecting - use the correct interface
    ACTUAL_TUN=$(ip link show | grep -o "tun[0-9]\+" | head -n 1)
    if [ -n "$ACTUAL_TUN" ]; then
        log "DEBUG" "Cleaning up TC rules for $ACTUAL_TUN"
        tc qdisc del dev "$ACTUAL_TUN" root 2>/dev/null || true
    fi
    
    exit 0
}

# Capture signals for cleanup (added SIGHUP)
trap cleanup SIGINT SIGTERM SIGHUP EXIT

# Verify root privileges
if [ "$(id -u)" -ne 0 ]; then
    log "ERROR" "This script must be run as root"
    echo "Please run with: sudo $0"
    exit 1
fi

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Start VPN connection
start_vpn() {
    local config_file=$1
    local vpn_server=$2
    
    log "INFO" "Starting VPN connection to $vpn_server using $config_file"
    
    # Verify that the configuration file exists
    if [ ! -f "$config_file" ]; then
        log "ERROR" "Configuration file $config_file does not exist"
        exit 1
    fi
    
    # Backup current iptables rules
    log "INFO" "Backing up current iptables rules"
    BACKUP_TIMESTAMP=$(date +%Y%m%d%H%M%S)
    LATEST_BACKUP="$BACKUP_DIR/iptables-$BACKUP_TIMESTAMP.bak"
    iptables-save > "$LATEST_BACKUP"
    log "INFO" "Rules backed up to $LATEST_BACKUP"
    
    # Clean old backups
    log "DEBUG" "Cleaning old backups (keeping last $MAX_BACKUPS)"
    find "$BACKUP_DIR" -name "iptables-*.bak" -type f | sort -r | tail -n +$((MAX_BACKUPS+1)) | xargs rm -f 2>/dev/null || true
    
    # Connect to VPN
    log "INFO" "Connecting to VPN using config file: $config_file"
    log "INFO" "VPN interface detected from config file: $VPN_INTERFACE"
    
    # Start OpenVPN in the background, redirecting warnings
    openvpn --config "$config_file" --daemon 2>/tmp/openvpn_warnings.log
    
    # Show important warnings
    if [ -f "/tmp/openvpn_warnings.log" ]; then
        if grep -q "WARNING" /tmp/openvpn_warnings.log; then
            log "WARN" "OpenVPN showed warnings (non-critical):"
            grep "WARNING" /tmp/openvpn_warnings.log | while read -r line; do
                log "WARN" "OpenVPN: $line"
            done
        fi
    fi
    
    # Wait for VPN interface to appear
    log "INFO" "Waiting for VPN interface $VPN_INTERFACE to come up..."
    for ((i=1; i<=VPN_TIMEOUT; i++)); do
        if ip link show | grep -q "$VPN_INTERFACE"; then
            log "INFO" "VPN interface $VPN_INTERFACE is up!"
            setup_iptables
            return 0
        fi
        log "DEBUG" "Waiting for VPN interface... ${i}s of ${VPN_TIMEOUT}s"
        echo -en "\r [${i}s of ${VPN_TIMEOUT}s]"
        sleep 1
    done
    
    log "ERROR" "VPN interface $VPN_INTERFACE did not come up within $VPN_TIMEOUT seconds"
    return 1
}

# Configure iptables for the VPN
setup_iptables() {
    log "INFO" "Setting up iptables and traffic control rules for SafeVPN"
    
    # Detect the specific tun interface in use
    local ACTUAL_TUN
    ACTUAL_TUN=$(ip link show | grep -o "tun[0-9]\+" | head -n 1)
    if [ -z "$ACTUAL_TUN" ]; then
        log "ERROR" "Could not detect an active tun interface"
        exit 1
    fi
    
    log "DEBUG" "Detected VPN interface: $ACTUAL_TUN"
    VPN_INTERFACE=$ACTUAL_TUN
    
    # Get the main network interface
    local MAIN_INTERFACE
    MAIN_INTERFACE=$(ip route | grep default | awk '{print $5}')
    log "DEBUG" "Main interface detected: $MAIN_INTERFACE"
    
    # Verify server IP
    if [ "$VPN_SERVER" = "Unknown" ]; then
        log "ERROR" "VPN server IP not provided"
        exit 1
    fi
    
    log "INFO" "Configuring rules for VPN server: $VPN_SERVER"
    
    # Clear existing rules
    iptables -F
    iptables -N SAFEVPN 2>/dev/null || true
    iptables -F SAFEVPN
    
    # Remove any existing tc rules
    tc qdisc del dev "$VPN_INTERFACE" root 2>/dev/null || true
    
    # Configure tc for advanced packet filtering
    log "DEBUG" "Configuring Traffic Control (tc) rules"
    tc qdisc add dev "$VPN_INTERFACE" root handle 1: prio
    tc filter add dev "$VPN_INTERFACE" protocol ip parent 1: prio 1 u32 match ip dst "$VPN_SERVER" flowid 1:1
    tc filter add dev "$VPN_INTERFACE" protocol ip parent 1: prio 2 u32 match ip src "$VPN_SERVER" flowid 1:1
    
    # Get all VPN subnets
    local VPN_SUBNETS
    VPN_SUBNETS=$(ip route | grep "$VPN_INTERFACE" | awk '{print $1}')
    
    # Use tc to block other subnets besides the VPN server
    for subnet in $VPN_SUBNETS; do
        if [[ "$subnet" != *"$VPN_SERVER"* ]]; then
            log "INFO" "Blocking VPN subnet: $subnet"
            tc filter add dev "$VPN_INTERFACE" protocol ip parent 1: prio 3 u32 match ip dst "$subnet" action drop
        fi
    done
    
    # Default policies - ACCEPT normal traffic
    iptables -P INPUT ACCEPT
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # ===== IMPORTANT: FIRST allow traffic to VPN server =====
    iptables -A OUTPUT -o "$VPN_INTERFACE" -d "$VPN_SERVER" -j ACCEPT
    iptables -A INPUT -i "$VPN_INTERFACE" -s "$VPN_SERVER" -j ACCEPT
    
    # ===== THEN block all other VPN traffic =====
    iptables -A OUTPUT -o "$VPN_INTERFACE" -j DROP
    iptables -A INPUT -i "$VPN_INTERFACE" -j DROP
    
    log "INFO" "SafeVPN traffic control rules configured successfully"
}

# Show VPN status
show_status() {
    local count=0
    # Keep the script running until the user stops it
    log "INFO" "VPN connection established. Press Ctrl+C to disconnect.\n"
    echo ""
    echo "---------------------------------------------------------"
    echo "                VPN CONNECTED SUCCESSFULLY                "
    echo "---------------------------------------------------------"
    echo ""
    echo " * Public IP: $(curl -s --max-time 5 https://ifconfig.me || curl -s --max-time 5 https://api.ipify.org || curl -s --max-time 5 https://checkip.amazonaws.com || echo "Unable to determine")"
    echo " * DNS servers:"
    if command -v resolvectl &>/dev/null; then
        dns_info=$(resolvectl status 2>/dev/null | grep -E "Current DNS Server|DNS Servers|Fallback DNS" | sed 's/^[[:space:]]*//')
        if [ -n "$dns_info" ]; then
            echo "$dns_info" | sed 's/^/   - /'
        else
            echo "   - Unable to retrieve DNS information"
        fi
    else
        echo "   - resolvectl not available, checking /etc/resolv.conf"
        nameservers=$(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}')
        if [ -n "$nameservers" ]; then
            for ns in $nameservers; do
                echo "   - $ns"
            done
        else
            echo "   - No DNS servers found"
        fi
    fi
    echo " * Interface: $VPN_INTERFACE"
    echo " * Remote Server: $(grep "^remote " "$CONFIG_FILE" | awk '{print $2 " port " $3}' 2>/dev/null || echo "Not specified in config") (Protocol: $(grep "^proto " "$CONFIG_FILE" | awk '{print $2}' 2>/dev/null || echo "tcp"))"
    echo " * VPN IP address: $(ip addr show "$VPN_INTERFACE" | grep 'inet ' | awk '{print $2}')"
    echo " * Gateway: $(ip route | grep "$VPN_INTERFACE" | grep -m 1 "via" | awk '{print $3}')"
    echo " * Server: $VPN_SERVER"

    echo " * Available VPN networks"
    ip route | grep "$VPN_INTERFACE" | awk '{print "   - " $1}'
    echo ""
    echo "---------------------------------------------------------"
    while true; do
        if ! ip link show | grep -q "$VPN_INTERFACE"; then
            log "ERROR" "VPN connection lost!"
            exit 1
        fi
        
        count=$((count + 1))
        if [ $count -gt 10 ]; then
            count=0
            echo -en "\r VPN Connected [✓] - Press Ctrl+C to disconnect "
        fi
        
        sleep 1
    done
}

echo "
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   ░░░░░░░░░░░░░   ░░░░░░░░░   ░        ░░░    ░░░░░   ░░░░░░
▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒   ▒▒▒▒▒▒▒   ▒▒   ▒▒▒▒   ▒  ▒   ▒▒▒   ▒▒▒▒▒▒
▒▒▒▒▒▒▒▒     ▒▒▒▒▒   ▒▒▒▒▒    ▒  ▒▒▒▒▒   ▒▒▒▒▒▒▒   ▒▒▒▒▒   ▒▒▒   ▒▒▒▒   ▒   ▒   ▒▒   ▒▒▒▒▒▒
▓▓▓▓▓▓▓   ▓▓▓▓▓▓   ▓▓   ▓▓▓▓   ▓▓▓▓▓  ▓▓▓   ▓▓▓▓▓   ▓▓▓   ▓▓▓▓        ▓▓▓   ▓▓   ▓   ▓▓▓▓▓▓
▓▓▓▓▓▓▓▓▓    ▓▓   ▓▓▓   ▓▓▓▓   ▓▓▓▓         ▓▓▓▓▓▓   ▓   ▓▓▓▓▓   ▓▓▓▓▓▓▓▓   ▓▓▓  ▓   ▓▓▓▓▓▓
▓▓▓▓▓▓▓▓▓▓▓   ▓   ▓▓▓   ▓▓▓▓   ▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓     ▓▓▓▓▓▓   ▓▓▓▓▓▓▓▓   ▓▓▓▓  ▓  ▓▓▓▓▓▓
███████      ████   █    ███   ██████     ██████████   ███████   ████████   ██████   ██████
███████████████████████████████████████████████████████████████████████████████████████████

"
# Check arguments
if [ $# -lt 1 ]; then
    echo "  Usage: $0 <config_file.ovpn> [vpn_server]"
    echo "  Example: $0 file.ovpn 10.10.10.10"
    exit 1
fi

CONFIG_FILE=$1
VPN_SERVER=${2:-"Unknown"}

# Verify required tools before starting
check_requirements

# Start the process
start_vpn "$CONFIG_FILE" "$VPN_SERVER"

# Show dynamic status
show_status
