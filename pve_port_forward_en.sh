#!/bin/bash

# Force locale to UTF-8
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Configuration file paths
DB_FILE="/etc/nat_rules.db"
NFT_CONF="/etc/nftables.conf"

# Color definitions
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# Check for Root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script as root!${NC}"
  exit 1
fi

# Initialize database file
if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
fi

# Ensure IP forwarding and Nftables startup are enabled
setup_forwarding_env() {
    # If the file does not exist (-f) OR (||) the line is missing, write the config
    if [ ! -f /etc/sysctl.conf ] || ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "Kernel forwarding not enabled. Configuring..."
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf > /dev/null
    fi
    
    # Check if nftables is enabled on boot
    if ! systemctl is-enabled --quiet nftables; then
        echo "nftables not enabled on boot. Enabling now..."
        systemctl enable nftables > /dev/null 2>&1
    fi
}

# Core function: Generate nftables config from database and apply
apply_rules() {
    # Start generating configuration file (This overwrites existing nftables.conf)
    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        
EOF

    # ---------------------------------------------------------
    # First Pass: Generate NAT (DNAT) rules
    # ---------------------------------------------------------
    while IFS='|' read -r lport backend_ip backend_port proto remark status whitelist; do
        if [[ -n "$lport" ]]; then
            # status: 1=Enabled, 0=Paused (Defaults to 1 if empty)
            current_status=${status:-1}
            remark_text=${remark:-None}
            current_whitelist=${whitelist// /}
            # Only write config if status is 1
            if [ "$current_status" == "1" ]; then
                # Add comments to config file for debugging
                echo "        # Remark: $remark_text" >> "$NFT_CONF"

                limit_str=""
                if [[ -n "$current_whitelist" ]]; then
                    # Replace Chinese comma with English comma just in case
                    safe_whitelist=${current_whitelist//，/,}

                    # Check if string contains comma
                    if [[ "$safe_whitelist" == *","* ]]; then
                        # Contains comma, treat as list, add braces
                        limit_str="ip saddr { $safe_whitelist } "
                    else
                        # No comma, treat as single IP, no braces
                        limit_str="ip saddr $safe_whitelist "
                    fi
                fi

                if [ "$proto" == "tcp+udp" ]; then
                    echo "        iifname \"vmbr0\" ${limit_str}tcp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                    echo "        iifname \"vmbr0\" ${limit_str}udp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                else
                    echo "        iifname \"vmbr0\" ${limit_str}$proto dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                fi
                echo "" >> "$NFT_CONF"
            fi
        fi
    done < "$DB_FILE"

    # Close nat table, start filter table
    cat >> "$NFT_CONF" <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        
        oifname "vmbr0" masquerade
    }
}

table ip filter {
    chain input { type filter hook input priority 0; policy accept; }
    
    chain forward { 
        # Default policy changed to drop (Deny all forwarding)
        type filter hook forward priority 0; policy drop; 
        
        tcp flags syn tcp option maxseg size set rt mtu
        
        # Allow established connection packets (Critical!), Without this, return packets are blocked and forwarding breaks.
        ct state established,related accept
        
        iifname "vmbr1" accept
EOF

    # ---------------------------------------------------------
    # Second Pass: Generate Filter (Forward) Whitelist rules
    # Note: Forward chain matches the Destination IP (Backend IP) and Port AFTER DNAT
    # ---------------------------------------------------------
    while IFS='|' read -r lport backend_ip backend_port proto remark status whitelist; do
        if [[ -n "$lport" ]]; then
            # status: 1=Enabled, 0=Paused (Defaults to 1 if empty)
            current_status=${status:-1}
            remark_text=${remark:-None}
            current_whitelist=${whitelist// /}
            # Only write config if status is 1
            if [ "$current_status" == "1" ]; then
                # Add comments to config file for debugging
                echo "        # Remark: $remark_text" >> "$NFT_CONF"
                
                # Handle Whitelist (for Forward)
                # If NAT layer limits Source IP, Forward layer should also limit it for double security
                limit_str=""
                if [[ -n "$current_whitelist" ]]; then
                    # Replace Chinese comma with English comma
                    safe_whitelist=${current_whitelist//，/,}

                    # Check if string contains comma
                    if [[ "$safe_whitelist" == *","* ]]; then
                        # Contains comma, treat as list, add braces
                        limit_str="ip saddr { $safe_whitelist } "
                    else
                        # No comma, treat as single IP or subnet, no braces
                        limit_str="ip saddr $safe_whitelist "
                    fi
                fi

                # Write Forward rules
                # Syntax: [Source Limit] ip daddr <Backend IP> <Proto> dport <Backend Port> accept
                if [ "$proto" == "tcp+udp" ]; then
                    echo "        ${limit_str}ip daddr $backend_ip tcp dport $backend_port accept" >> "$NFT_CONF"
                    echo "        ${limit_str}ip daddr $backend_ip udp dport $backend_port accept" >> "$NFT_CONF"
                else
                    echo "        ${limit_str}ip daddr $backend_ip $proto dport $backend_port accept" >> "$NFT_CONF"
                fi
                echo "" >> "$NFT_CONF"
            fi
        fi
    done < "$DB_FILE"

    # Finalize
    cat >> "$NFT_CONF" <<EOF
    }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF

    # Choose command based on Nftables service status
    if systemctl is-active --quiet nftables; then
        # Reload config if running
        systemctl reload nftables
    else
        # Restart service if stopped
        systemctl restart nftables
    fi
    
    local error_status=$?
    
    if [ $error_status -eq 0 ]; then
        echo -e "${GREEN}Configuration updated and applied successfully!${NC}"
        return 0
    else
        echo -e "${RED}Failed to apply configuration. Please check input validity.${NC}"
        # Output last few lines of error log for troubleshooting
        echo -e "${YELLOW}Error details (journalctl):${NC}"
        journalctl -xeu nftables.service | tail -n 10
        return 1
    fi
}

# --- Common Function: Print Rules Table ---
# Arg $1: Filter mode (all, enabled, paused)
# Return: 0=Data shown, 1=No data shown
show_rules_table() {
    local filter_mode=$1
    local found_count=0
    
    if [ ! -s "$DB_FILE" ]; then
        echo "No rules available."
        return 1
    fi

    # Unified Header
    printf "${YELLOW}%-4s %-8s %-10s %-12s %-16s %-12s %-12s %-s${NC}\n" "ID" "Status" "Proto" "LPort" "Dest IP" "Dest Port" "Src Limit" "Remark"
    echo "------------------------------------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r lport backend_ip backend_port proto remark status whitelist; do
        current_status=${status:-1}
        safe_remark=${remark:-"-"}
        
        # Determine whether to show this row
        local show_row=0
        if [ "$filter_mode" == "all" ]; then show_row=1; fi
        if [ "$filter_mode" == "enabled" ] && [ "$current_status" == "1" ]; then show_row=1; fi
        if [ "$filter_mode" == "paused" ] && [ "$current_status" == "0" ]; then show_row=1; fi

        if [ $show_row -eq 1 ]; then
            # Status Color
            if [ "$current_status" == "1" ]; then
                status_str="${GREEN}Active${NC}"
            else
                status_str="${RED}Paused${NC}"
            fi

            # Whitelist display
            if [[ -n "$whitelist" ]]; then
                wl_display="Yes"
            else
                wl_display="No"
            fi

            # Print Row
            printf "%-4s %-19b %-10s %-12s %-16s %-12s %-12s %-s\n" "$i" "$status_str" "$proto" "$lport" "$backend_ip" "$backend_port" "$wl_display" "$safe_remark"
            found_count=$((found_count + 1))
        fi
        
        # Increment line number regardless of visibility to match ID with file line number
        ((i++))
    done < "$DB_FILE"
    echo "======================"

    if [ $found_count -eq 0 ]; then
        if [ "$filter_mode" == "enabled" ]; then echo "No active rules found."; fi
        if [ "$filter_mode" == "paused" ]; then echo "No paused rules found."; fi
        return 1
    fi
    return 0
}

# 1. List all rules
list_rules() {
    echo -e "\n${CYAN}=== Current Rules List ===${NC}"
    show_rules_table "all"
}

# 2. Add rule
add_rule() {
    echo -e "\n${GREEN}>>> Add New Forwarding Rule${NC}"
    
    read -p "Local Listening Port (e.g., 8080): " lport
    read -p "Backend Real IP (e.g., 192.168.1.20): " backend_ip
    read -p "Backend Real Port (e.g., 80): " backend_port
    
    echo "Protocol Type:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP + UDP"
    read -p "Select (1-3): " p_choice
    
    case $p_choice in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="tcp+udp" ;;
        *) echo -e "${RED}Invalid selection${NC}"; return ;;
    esac

    read -p "Remark (Optional, do not include '|'): " user_remark
    # Remove pipe symbols that might break format
    user_remark=${user_remark//|/}
    
    echo -e "\n${YELLOW}Set Allowed Source IPs (Whitelist)${NC}"
    echo "Format = 1.1.1.1,192.168.1.0/24 (comma separated); Empty = Allow all IPs."
    read -p "Enter: " whitelist_input
    whitelist_input=${whitelist_input// /}
    whitelist_input=${whitelist_input//|/}
    whitelist_input=${whitelist_input//，/,}

    # Use awk for smarter protocol conflict detection
    # Logic:
    # 1. If port is same (Col 1 == lport)
    # 2. If existing proto == new proto -> Conflict
    # 3. If existing proto == "tcp+udp" -> Conflict regardless of new proto
    # 4. If new proto == "tcp+udp" -> Conflict if any rule exists on this port
    
    conflict_check=$(awk -F"|" -v new_port="$lport" -v new_proto="$proto" '
    $1 == new_port {
        if ($4 == new_proto || $4 == "tcp+udp" || new_proto == "tcp+udp") {
            print "1"
            exit
        }
    }' "$DB_FILE")

    if [ "$conflict_check" == "1" ]; then
        echo -e "${RED}Error: Protocol conflict on local port $lport!${NC}"
        echo -e "${YELLOW}Tip: The Port+Protocol pair conflicts with an existing rule. Do not add duplicates.${NC}"
        return
    fi
    
    # Backup original config
    cp "$DB_FILE" "${DB_FILE}.bak"
    
    echo "$lport|$backend_ip|$backend_port|$proto|$user_remark|1|$whitelist_input" >> "$DB_FILE"
    apply_rules
    
    # Error handling mechanism
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}>>> Configuration error detected. Auto-rolling back...${NC}"
        mv "${DB_FILE}.bak" "$DB_FILE" # Restore backup
        apply_rules > /dev/null 2>&1   # Re-apply old correct config
        echo -e "${GREEN}Rollback complete. New rule revoked. Please check service status.${NC}"
    else
        rm -f "${DB_FILE}.bak" # Delete backup on success
    fi
}

# Internal Function: Pause Rule
pause_rule_logic() {
    echo -e "\n${CYAN}>>> Pause Forwarding Rule${NC}"
    echo -e "(Showing currently [Active] rules only)"
    
    # Call common function to show "enabled" rules and check return value
    if ! show_rules_table "enabled"; then
        return
    fi

    read -p "Enter Rule ID to [Pause]: " target_id
    
    total_lines=$(wc -l < "$DB_FILE")
    if [[ "$target_id" =~ ^[0-9]+$ ]] && [ "$target_id" -le "$total_lines" ] && [ "$target_id" -gt 0 ]; then
        awk -v line="$target_id" -v FS="|" -v OFS="|" 'NR==line {$6="0"} {print}' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
        echo -e "${YELLOW}Rule ID $target_id paused.${NC}"
        apply_rules
    else
        echo -e "${RED}Invalid ID${NC}"
    fi
}

# Internal Function: Enable Rule
enable_rule_logic() {
    echo -e "\n${CYAN}>>> Enable Forwarding Rule${NC}"
    echo -e "(Showing currently [Paused] rules only)"
    
    # Call common function to show "paused" rules and check return value
    if ! show_rules_table "paused"; then
        return
    fi

    read -p "Enter Rule ID to [Enable]: " target_id
    
    total_lines=$(wc -l < "$DB_FILE")
    if [[ "$target_id" =~ ^[0-9]+$ ]] && [ "$target_id" -le "$total_lines" ] && [ "$target_id" -gt 0 ]; then
        awk -v line="$target_id" -v FS="|" -v OFS="|" 'NR==line {$6="1"} {print}' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
        echo -e "${GREEN}Rule ID $target_id re-enabled.${NC}"
        apply_rules
    else
        echo -e "${RED}Invalid ID${NC}"
    fi
}

# 3. Manage Rule State (Sub-menu)
manage_state() {
    echo -e "\n${YELLOW}>>> Manage Rule State${NC}"
    echo "1. Pause Rule"
    echo "2. Enable Rule"
    echo "3. Back to Main Menu"
    read -p "Select option [1-3]: " sub_choice
    
    case $sub_choice in
        1) pause_rule_logic ;;
        2) enable_rule_logic ;;
        3) return ;;
        *) echo "Invalid input" ;;
    esac
}

# 4. Delete Rule
del_rule() {
    echo -e "\n${RED}>>> Delete Forwarding Rule${NC}"
    # Use "all" mode to let user see everything before deleting
    if ! show_rules_table "all"; then
        return
    fi
    
    read -p "Enter Rule ID to delete: " del_id
    total_lines=$(wc -l < "$DB_FILE")
    
    if [[ "$del_id" =~ ^[0-9]+$ ]] && [ "$del_id" -le "$total_lines" ] && [ "$del_id" -gt 0 ]; then
        sed -i "${del_id}d" "$DB_FILE"
        apply_rules
    else
        echo -e "${RED}Invalid ID${NC}"
    fi
}

# 5. Restore/Reload Config
restore_config() {
    echo -e "\n${YELLOW}>>> Restoring configuration...${NC}"
    # Check if database has content
    if [ ! -s "$DB_FILE" ]; then
        echo -e "${RED}Error: Database file (/etc/nat_rules.db) is empty or missing. Cannot restore.${NC}"
        echo -e "Please add at least one rule first."
        return
    fi
    # Force call apply_rules to rewrite and restart
    echo "Reading database and rewriting nftables configuration..."
    apply_rules
}

# Main Menu
setup_forwarding_env
while true; do
    echo -e "\n${CYAN}PVE Transparent Forwarding Manager (nftables)${NC}"
    if systemctl is-active --quiet nftables; then
        nft_status="${GREEN}● Running${NC}"
    else
        nft_status="${RED}● Stopped${NC}"
    fi
    echo -e "Service Status: ${nft_status}${NC}"
    echo "1. List All Rules"
    echo "2. Add Forwarding Rule"
    echo "3. Pause/Enable Rules"
    echo "4. Delete Forwarding Rule"
    echo "5. Restore/Reload Config"
    echo "6. Exit"
    read -p "Select option [1-6]: " choice

    case $choice in
        1) list_rules ;;
        2) add_rule ;;
        3) manage_state ;;
        4) del_rule ;;
        5) restore_config ;;
        6) exit 0 ;;
        *) echo "Invalid input" ;;
    esac
done