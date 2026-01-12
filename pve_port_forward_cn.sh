#!/bin/bash

# 配置文件路径
DB_FILE="/etc/nat_rules.db"
NFT_CONF="/etc/nftables.conf"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查 Root 权限
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 sudo 运行此脚本！${NC}"
  exit 1
fi

# 初始化数据库文件
if [ ! -f "$DB_FILE" ]; then
    touch "$DB_FILE"
fi

# 确保开启内核转发
enable_forwarding() {
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p > /dev/null
    fi
}

# 核心函数：根据数据库生成 nftables 配置并应用
apply_rules() {
    # 开始生成配置文件（这将覆盖原有的 nftables.conf）
    cat > "$NFT_CONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
EOF

    # 读取数据库并写入 DNAT 规则
    # 格式: lport|backend_ip|backend_port|proto|remark
    while IFS='|' read -r lport backend_ip backend_port proto remark; do
        if [[ -n "$lport" ]]; then
            # 处理备注为空的情况
            remark_text=${remark:-无}
            
            # 在配置文件中添加注释，方便调试
            echo "        # 备注: $remark_text" >> "$NFT_CONF"

            # 写入规则
            if [ "$proto" == "tcp+udp" ]; then
                echo "        tcp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                echo "        udp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
            else
                echo "        $proto dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
            fi
            echo "" >> "$NFT_CONF"
        fi
    done < "$DB_FILE"

    cat >> "$NFT_CONF" <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        # 不做 Masquerade，保留源 IP
    }
}

table ip filter {
    chain input { type filter hook input priority 0; policy accept; }
    chain forward { 
        type filter hook forward priority 0; policy accept; 
        # 允许所有转发流量通过
    }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF

    # 重启 nftables 应用配置
    systemctl enable nftables > /dev/null 2>&1
    systemctl restart nftables
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}配置已更新并生效！${NC}"
    else
        echo -e "${RED}应用配置失败，请检查输入是否合法。${NC}"
    fi
}

# 1. 查看规则
list_rules() {
    echo -e "\n${CYAN}=== 当前转发规则 ===${NC}"
    if [ ! -s "$DB_FILE" ]; then
        echo "暂无规则。"
    else
        # 调整表头，增加备注列
        printf "${YELLOW}%-4s %-10s %-10s %-18s %-10s %-s${NC}\n" "ID" "协议" "本地端口" "目标IP" "目标端口" "备注"
        echo "--------------------------------------------------------------------------------"
        i=1
        while IFS='|' read -r lport backend_ip backend_port proto remark; do
            # 如果备注为空，显示 -
            safe_remark=${remark:-"-"}
            printf "%-4s %-10s %-10s %-18s %-10s %-s\n" "$i" "$proto" "$lport" "$backend_ip" "$backend_port" "$safe_remark"
            ((i++))
        done < "$DB_FILE"
    fi
    echo "======================"
}

# 2. 添加规则
add_rule() {
    echo -e "\n${GREEN}>>> 新增转发规则${NC}"
    
    read -p "本地监听端口 (如 8080): " lport
    read -p "后端真实 IP (如 192.168.1.20): " backend_ip
    read -p "后端真实端口 (如 80): " backend_port
    
    echo "协议类型:"
    echo "1) TCP"
    echo "2) UDP"
    echo "3) TCP + UDP"
    read -p "选择 (1-3): " p_choice
    
    case $p_choice in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="tcp+udp" ;;
        *) echo -e "${RED}无效选择${NC}"; return ;;
    esac

    # 输入备注
    read -p "备注说明 (选填，勿包含'|'符号): " user_remark
    # 去除可能破坏格式的管道符
    user_remark=${user_remark//|/}

    # 简单查重
    if grep -q "^$lport|" "$DB_FILE"; then
        echo -e "${RED}错误：本地端口 $lport 已存在规则，请先删除旧规则。${NC}"
        return
    fi

    # 写入文件：本地端口|目标IP|目标端口|协议|备注
    echo "$lport|$backend_ip|$backend_port|$proto|$user_remark" >> "$DB_FILE"
    apply_rules
}

# 3. 删除规则
del_rule() {
    list_rules
    if [ ! -s "$DB_FILE" ]; then return; fi
    
    read -p "请输入要删除的规则 ID: " del_id
    
    # 获取总行数
    total_lines=$(wc -l < "$DB_FILE")
    
    if [[ "$del_id" =~ ^[0-9]+$ ]] && [ "$del_id" -le "$total_lines" ] && [ "$del_id" -gt 0 ]; then
        sed -i "${del_id}d" "$DB_FILE"
        apply_rules
    else
        echo -e "${RED}无效的 ID${NC}"
    fi
}

# 4. 恢复/重载配置 (新功能)
restore_config() {
    echo -e "\n${YELLOW}>>> 正在恢复配置...${NC}"
    
    # 检查数据库是否有内容
    if [ ! -s "$DB_FILE" ]; then
        echo -e "${RED}错误：数据库文件 (/etc/nat_rules.db) 为空或不存在，无法恢复。${NC}"
        echo -e "请先添加至少一条规则。"
        return
    fi
    
    # 强制调用 apply_rules 进行重写和重启
    echo "正在读取数据库并重写 nftables 配置文件..."
    apply_rules
}
# 主菜单
enable_forwarding
while true; do
    echo -e "\n${CYAN}PVE 透明转发管理-基于nftables${NC}"
    echo "1. 查看当前规则"
    echo "2. 添加转发规则"
    echo "3. 删除转发规则"
    echo "4. 恢复/重载配置"
    echo "5. 退出"
    read -p "请输入选项 [1-5]: " choice

    case $choice in
        1) list_rules ;;
        2) add_rule ;;
        3) del_rule ;;
        4) restore_config ;;
        5) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done