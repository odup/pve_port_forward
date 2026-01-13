#!/bin/bash

# Configuration file paths
DB_FILE="/etc/nat_rules.db"
NFT_CONF="/etc/nftables.conf"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Check Root privileges
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run this script with sudo!${NC}"
  exit 1
fi

# Initialize database file
if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
fi

# Ensure kernel forwarding is enabled
enable_forwarding() {
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi
}

# Core function: Generate nftables config from DB and apply
apply_rules() {
    # Start generating config file (This will overwrite existing nftables.conf)
    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    # Read database and write DNAT rules
    # Format: lport|backend_ip|backend_port|proto|remark|status
    # status: 1=Enabled, 0=Paused (defaults to 1 if empty)
    while IFS='|' read -r lport backend_ip backend_port proto remark status; do
        if [[ -n "$lport" ]]; then
            # Backward compatibility: status defaults to 1 (Active) if empty
            current_status=${status:-1}
            remark_text=${remark:-None}

            # Only write to config if status is 1
            if [ "$current_status" == "1" ]; then
                # Add comment to config file for debugging
                echo "        # Remark: $remark_text" >> "$NFT_CONF"
                if [ "$proto" == "tcp+udp" ]; then
                    echo "        tcp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                    echo "        udp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                else
                    echo "        $proto dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                fi
                echo "" >> "$NFT_CONF"
            fi
        fi
    done < "$DB_FILE"

    cat >> "$NFT_CONF" <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # No Masquerade, preserve source IP
    }
}

table ip filter {
    chain input { type filter hook input priority 0; policy accept; }
    chain forward { 
        type filter hook forward priority 0; policy accept; 
        # Allow all forwarded traffic
    }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF

    # Restart nftables to apply config
    systemctl enable nftables > /dev/null 2>&1
    systemctl restart nftables
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Configuration updated and applied successfully!${NC}"
    else
        echo -e "${RED}Failed to apply configuration. Please check your inputs.${NC}"
    fi
}

# 1. List all rules
list_rules() {
    echo -e "\n${CYAN}=== Current Rules ===${NC}"
    if [ ! -s "$DB_FILE" ]; then
        echo "No rules found."
    else
        printf "${YELLOW}%-4s %-8s %-10s %-10s %-16s %-10s %-s${NC}\n" "ID" "Status" "Proto" "L-Port" "Dest IP" "Dest Port" "Remark"
        echo "---------------------------------------------------------------------------------------"
        i=1
        while IFS='|' read -r lport backend_ip backend_port proto remark status; do
            safe_remark=${remark:-"-"}
            current_status=${status:-1}
            
            if [ "$current_status" == "1" ]; then
                status_str="${GREEN}Active${NC}"
            else
                status_str="${RED}Paused${NC}"
            fi
            
            printf "%-4s %-14b %-10s %-10s %-16s %-10s %-s\n" "$i" "$status_str" "$proto" "$lport" "$backend_ip" "$backend_port" "$safe_remark"
            ((i++))
        done < "$DB_FILE"
    fi
    echo "======================"
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

    read -p "Remark (Optional, do not use '|'): " user_remark
    # Remove pipe characters that might break formatting
    user_remark=${user_remark//|/}

    # Simple duplicate check
    if grep -q "^$lport|" "$DB_FILE"; then
        echo -e "${RED}Error: Rule for local port $lport already exists. Please delete the old rule first.${NC}"
        return
    fi

    # Write to file: lport|backend_ip|backend_port|proto|remark|status(default 1)
    echo "$lport|$backend_ip|$backend_port|$proto|$user_remark|1" >> "$DB_FILE"
    apply_rules
}

# Internal function: Pause rule
pause_rule_logic() {
    echo -e "\n${CYAN}>>> Pause Forwarding Rule${NC}"
    echo -e "(Showing only currently [Active] rules)"
    
    found=0
    i=1
    printf "${YELLOW}%-4s %-10s %-10s %-16s %-s${NC}\n" "ID" "Proto" "L-Port" "Dest IP" "Remark"
    echo "--------------------------------------------------------"
    while IFS='|' read -r lport backend_ip backend_port proto remark status; do
        current_status=${status:-1}
        if [ "$current_status" == "1" ]; then
             printf "%-4s %-10s %-10s %-16s %-s\n" "$i" "$proto" "$lport" "$backend_ip" "${remark:-"-"}"
             found=1
        fi
        ((i++))
    done < "$DB_FILE"

    if [ $found -eq 0 ]; then
        echo "No active rules available to pause."
        return
    fi

    read -p "Enter ID to [Pause]: " target_id
    
    total_lines=$(wc -l < "$DB_FILE")
    if [[ "$target_id" =~ ^[0-9]+$ ]] && [ "$target_id" -le "$total_lines" ] && [ "$target_id" -gt 0 ]; then
        awk -v line="$target_id" -v FS="|" -v OFS="|" 'NR==line {$6="0"} {print}' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
        echo -e "${YELLOW}Rule ID $target_id has been paused.${NC}"
        apply_rules
    else
        echo -e "${RED}Invalid ID${NC}"
    fi
}

# Internal function: Resume rule
enable_rule_logic() {
    echo -e "\n${CYAN}>>> Resume Forwarding Rule${NC}"
    echo -e "(Showing only currently [Paused] rules)"
    
    found=0
    i=1
    printf "${YELLOW}%-4s %-10s %-10s %-16s %-s${NC}\n" "ID" "Proto" "L-Port" "Dest IP" "Remark"
    echo "--------------------------------------------------------"
    while IFS='|' read -r lport backend_ip backend_port proto remark status; do
        current_status=${status:-1}
        if [ "$current_status" == "0" ]; then
             printf "%-4s %-10s %-10s %-16s %-s\n" "$i" "$proto" "$lport" "$backend_ip" "${remark:-"-"}"
             found=1
        fi
        ((i++))
    done < "$DB_FILE"

    if [ $found -eq 0 ]; then
        echo "No paused rules available to resume."
        return
    fi

    read -p "Enter ID to [Resume]: " target_id
    
    total_lines=$(wc -l < "$DB_FILE")
    if [[ "$target_id" =~ ^[0-9]+$ ]] && [ "$target_id" -le "$total_lines" ] && [ "$target_id" -gt 0 ]; then
        awk -v line="$target_id" -v FS="|" -v OFS="|" 'NR==line {$6="1"} {print}' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
        echo -e "${GREEN}Rule ID $target_id has been resumed.${NC}"
        apply_rules
    else
        echo -e "${RED}Invalid ID${NC}"
    fi
}

# 3. Manage Rule Status (Sub-menu)
manage_state() {
    echo -e "\n${YELLOW}>>> Manage Rule Status${NC}"
    echo "1. Pause Rule"
    echo "2. Enable Rule"
    echo "3. Return to Main Menu"
    read -p "Select option [1-3]: " sub_choice
    
    case $sub_choice in
        1) pause_rule_logic ;;
        2) enable_rule_logic ;;
        3) return ;;
        *) echo "Invalid input" ;;
    esac
}

# 4. Delete rule
del_rule() {
    list_rules
    if [ ! -s "$DB_FILE" ]; then return; fi
    
    read -p "Enter Rule ID to delete: " del_id
    # Get total lines
    total_lines=$(wc -l < "$DB_FILE")
    
    if [[ "$del_id" =~ ^[0-9]+$ ]] && [ "$del_id" -le "$total_lines" ] && [ "$del_id" -gt 0 ]; then
        sed -i "${del_id}d" "$DB_FILE"
        apply_rules
    else
        echo -e "${RED}Invalid ID${NC}"
    fi
}

# 5. Restore/Reload Configuration
restore_config() {
    echo -e "\n${YELLOW}>>> Restoring configuration...${NC}"
    # Check if database has content
    if [ ! -s "$DB_FILE" ]; then
        echo -e "${RED}Error: Database file (/etc/nat_rules.db) is empty or missing, cannot restore.${NC}"
        echo -e "Please add at least one rule first."
        return
    fi
    # Force call apply_rules to rewrite and restart
    echo "Reading database and rewriting nftables config file..."
    apply_rules
}

# Main Menu
enable_forwarding
while true; do
    echo -e "\n${CYAN}PVE Transparent Forwarding Manager (nftables)${NC}"
    echo "1. List All Rules"
    echo "2. Add Forwarding Rule"
    echo "3. Pause/Enable Rules"
    echo "4. Delete Forwarding Rule"
    echo "5. Restore/Reload Config"
    echo "6. Exit"
    read -p "Enter option [1-6]: " choice

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