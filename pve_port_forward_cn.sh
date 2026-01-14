#!/bin/bash

# 强制设置语言环境为 UTF-8
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

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
    # 如果文件不存在(-f) 或者(||) 文件中没有这行配置，则写入
    if [ ! -f /etc/sysctl.conf ] || ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p /etc/sysctl.conf > /dev/null
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

    # ---------------------------------------------------------
    # 第一遍循环：生成 NAT (DNAT) 规则
    # ---------------------------------------------------------
    while IFS='|' read -r lport backend_ip backend_port proto remark status whitelist; do
        if [[ -n "$lport" ]]; then
            # status: 1=启用, 0=暂停 (如果为空默认为1)
            current_status=${status:-1}
            remark_text=${remark:-无}
            current_whitelist=${whitelist// /}
            # 只有当状态为 1 时才写入配置
            if [ "$current_status" == "1" ]; then
                # 在配置文件中添加注释，方便调试
                echo "        # 备注: $remark_text" >> "$NFT_CONF"

                limit_str=""
                if [[ -n "$current_whitelist" ]]; then
                    # 替换中文逗号为英文逗号
                    safe_whitelist=${current_whitelist//，/,}

                    # 判断字符串中是否包含逗号
                    if [[ "$safe_whitelist" == *","* ]]; then
                        # 包含逗号，视为 IP 列表，加上花括号
                        limit_str="ip saddr { $safe_whitelist } "
                    else
                        # 不包含逗号，视为单个 IP，不加花括号
                        limit_str="ip saddr $safe_whitelist "
                    fi
                fi

                if [ "$proto" == "tcp+udp" ]; then
                    echo "        ${limit_str}tcp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                    echo "        ${limit_str}udp dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                else
                    echo "        ${limit_str}$proto dport $lport dnat to $backend_ip:$backend_port" >> "$NFT_CONF"
                fi
                echo "" >> "$NFT_CONF"
            fi
        fi
    done < "$DB_FILE"

    # 关闭 nat 表，开始 filter 表
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
        # 默认策略改为 drop (拒绝所有转发)
        type filter hook forward priority 0; policy drop; 
        
        # 允许已建立连接的回包（关键！）如果不加这句，回包会被拦截，转发也会断
        ct state established,related accept
        
EOF

    # ---------------------------------------------------------
    # 第二遍循环：生成 Filter (Forward) 白名单规则
    # 注意：Forward 链匹配的是 DNAT 之后的目标 IP (后端IP) 和 端口
    # ---------------------------------------------------------
    while IFS='|' read -r lport backend_ip backend_port proto remark status whitelist; do
        if [[ -n "$lport" ]]; then
            # status: 1=启用, 0=暂停 (如果为空默认为1)
            current_status=${status:-1}
            remark_text=${remark:-无}
            current_whitelist=${whitelist// /}
            # 只有当状态为 1 时才写入配置
            if [ "$current_status" == "1" ]; then
                # 在配置文件中添加注释，方便调试
                echo "        # 备注: $remark_text" >> "$NFT_CONF"
                
                # 处理白名单 (用于 Forward)
                # 如果 NAT 层限制了源IP，Forward 层最好也加上同样的限制，实现双重保险
                limit_str=""
                if [[ -n "$current_whitelist" ]]; then
                    # 替换中文逗号为英文逗号
                    safe_whitelist=${current_whitelist//，/,}

                    # 判断字符串中是否包含逗号
                    if [[ "$safe_whitelist" == *","* ]]; then
                        # 包含逗号，视为 IP 列表，加上花括号
                        limit_str="ip saddr { $safe_whitelist } "
                    else
                        # 不包含逗号，视为单个 IP，不加花括号
                        limit_str="ip saddr $safe_whitelist "
                    fi
                fi

                # 写入 Forward 规则
                # 语法: [源IP限制] ip daddr <后端IP> <协议> dport <后端端口> accept
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

    # 收尾
    cat >> "$NFT_CONF" <<EOF
    }
    chain output { type filter hook output priority 0; policy accept; }
}
EOF

    # 重启 nftables 应用配置
    systemctl enable nftables > /dev/null 2>&1
    systemctl restart nftables
	
    local error_status=$?
    
    if [ $error_status -eq 0 ]; then
        echo -e "${GREEN}配置已更新并生效！${NC}"
        return 0
    else
        echo -e "${RED}应用配置失败，请检查输入是否合法。${NC}"
        # 输出错误日志最后几行帮助排查
        echo -e "${YELLOW}错误详情 (journalctl):${NC}"
        journalctl -xeu nftables.service | tail -n 10
        return 1
    fi
}

# --- 公共函数：打印规则表格 ---
# 参数 $1: 过滤模式 (all, enabled, paused)
# 返回值: 0=有数据显示, 1=无数据显示
show_rules_table() {
    local filter_mode=$1
    local found_count=0
    
    if [ ! -s "$DB_FILE" ]; then
        echo "暂无规则。"
        return 1
    fi

    # 统一表头
    printf "${YELLOW}%-4s %-8s %-10s %-12s %-16s %-12s %-12s %-s${NC}\n" "ID" "状态" "协议" "本地端口" "目标IP" "目标端口" "源IP限制" "备注"
    echo "------------------------------------------------------------------------------------------------"

    local i=1
    while IFS='|' read -r lport backend_ip backend_port proto remark status whitelist; do
        current_status=${status:-1}
        safe_remark=${remark:-"-"}
        
        # 确定是否显示该行
        local show_row=0
        if [ "$filter_mode" == "all" ]; then show_row=1; fi
        if [ "$filter_mode" == "enabled" ] && [ "$current_status" == "1" ]; then show_row=1; fi
        if [ "$filter_mode" == "paused" ] && [ "$current_status" == "0" ]; then show_row=1; fi

        if [ $show_row -eq 1 ]; then
            # 状态颜色
            if [ "$current_status" == "1" ]; then
                status_str="${GREEN}开启${NC}"
            else
                status_str="${RED}暂停${NC}"
            fi

            # 白名单显示
            if [[ -n "$whitelist" ]]; then
                wl_display="有"
            else
                wl_display="无"
            fi

            # 打印行
            printf "%-4s %-19b %-10s %-8s %-16s %-8s %-9s %-s\n" "$i" "$status_str" "$proto" "$lport" "$backend_ip" "$backend_port" "$wl_display" "$safe_remark"
            found_count=$((found_count + 1))
        fi
        
        # 无论是否显示，行号必须自增，以保持ID与文件行号一致
        ((i++))
    done < "$DB_FILE"
    echo "======================"

    if [ $found_count -eq 0 ]; then
        if [ "$filter_mode" == "enabled" ]; then echo "没有正在开启的规则。"; fi
        if [ "$filter_mode" == "paused" ]; then echo "没有已暂停的规则。"; fi
        return 1
    fi
    return 0
}

# 1. 查看所有规则
list_rules() {
    echo -e "\n${CYAN}=== 当前规则列表 ===${NC}"
    show_rules_table "all"
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

    read -p "备注说明 (选填，勿包含'|'符号): " user_remark
    # 去除可能破坏格式的管道符
    user_remark=${user_remark//|/}
    
    echo -e "\n${YELLOW}设置允许访问的源IP (白名单)${NC}"
    echo "格式 = 1.1.1.1,192.168.1.0/24 (逗号分隔)；留空 = 允许所有IP。"
    read -p "请输入: " whitelist_input
    whitelist_input=${whitelist_input// /}
    whitelist_input=${whitelist_input//|/}
    whitelist_input=${whitelist_input//，/,}

    # 使用 awk 进行更智能的协议冲突检测
    # 逻辑：
    # 1. 端口相同 (第1列 == lport) 时才检查
    # 2. 如果 已有协议 == 新协议 -> 冲突
    # 3. 如果 已有协议 == "tcp+udp" -> 无论新加什么都冲突
    # 4. 如果 新协议 == "tcp+udp" -> 只要该端口有任何规则都冲突
    
    conflict_check=$(awk -F"|" -v new_port="$lport" -v new_proto="$proto" '
    $1 == new_port {
        if ($4 == new_proto || $4 == "tcp+udp" || new_proto == "tcp+udp") {
            print "1"
            exit
        }
    }' "$DB_FILE")

    if [ "$conflict_check" == "1" ]; then
        echo -e "${RED}错误：本地端口 $lport 协议冲突！${NC}"
        echo -e "${YELLOW}提示：待添加的 端口+协议 与已存在的转发规则冲突，请勿重复添加。${NC}"
        return
    fi
	
	# 备份原来配置
	cp "$DB_FILE" "${DB_FILE}.bak"
	
    echo "$lport|$backend_ip|$backend_port|$proto|$user_remark|1|$whitelist_input" >> "$DB_FILE"
    apply_rules
	
	# 异常处理机制
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}>>> 检测到配置错误，正在自动回滚...${NC}"
        mv "${DB_FILE}.bak" "$DB_FILE" # 恢复备份
        apply_rules > /dev/null 2>&1   # 重新应用旧的正确配置
        echo -e "${GREEN}回滚完成。新增规则已撤销，请检查服务是否正常运行。${NC}"
    else
        rm -f "${DB_FILE}.bak" # 成功则删除备份
    fi
}

# 内部函数：暂停规则
pause_rule_logic() {
    echo -e "\n${CYAN}>>> 暂停转发规则${NC}"
    echo -e "(仅显示当前正在【开启】的规则)"
    
    # 调用公共函数显示 "enabled" 的规则，并获取返回值
    if ! show_rules_table "enabled"; then
        return
    fi

    read -p "请输入要【暂停】的规则 ID: " target_id
    
    total_lines=$(wc -l < "$DB_FILE")
    if [[ "$target_id" =~ ^[0-9]+$ ]] && [ "$target_id" -le "$total_lines" ] && [ "$target_id" -gt 0 ]; then
        awk -v line="$target_id" -v FS="|" -v OFS="|" 'NR==line {$6="0"} {print}' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
        echo -e "${YELLOW}规则 ID $target_id 已暂停。${NC}"
        apply_rules
    else
        echo -e "${RED}无效的 ID${NC}"
    fi
}

# 内部函数：开启规则
enable_rule_logic() {
    echo -e "\n${CYAN}>>> 开启转发规则${NC}"
    echo -e "(仅显示当前已【暂停】的规则)"
    
    # 调用公共函数显示 "paused" 的规则，并获取返回值
    if ! show_rules_table "paused"; then
        return
    fi

    read -p "请输入要【开启】的规则 ID: " target_id
    
    total_lines=$(wc -l < "$DB_FILE")
    if [[ "$target_id" =~ ^[0-9]+$ ]] && [ "$target_id" -le "$total_lines" ] && [ "$target_id" -gt 0 ]; then
        awk -v line="$target_id" -v FS="|" -v OFS="|" 'NR==line {$6="1"} {print}' "$DB_FILE" > "${DB_FILE}.tmp" && mv "${DB_FILE}.tmp" "$DB_FILE"
        echo -e "${GREEN}规则 ID $target_id 已重新开启。${NC}"
        apply_rules
    else
        echo -e "${RED}无效的 ID${NC}"
    fi
}

# 3. 管理规则状态（二级菜单）
manage_state() {
    echo -e "\n${YELLOW}>>> 管理规则状态${NC}"
    echo "1. 暂停规则"
    echo "2. 开启规则"
    echo "3. 返回上级菜单"
    read -p "请选择操作 [1-3]: " sub_choice
    
    case $sub_choice in
        1) pause_rule_logic ;;
        2) enable_rule_logic ;;
        3) return ;;
        *) echo "无效输入" ;;
    esac
}

# 4. 删除规则
del_rule() {
    echo -e "\n${RED}>>> 删除转发规则${NC}"
    # 这里直接调用 all 模式，方便用户查看所有规则后选择删除
    if ! show_rules_table "all"; then
        return
    fi
    
    read -p "请输入要删除的规则 ID: " del_id
    total_lines=$(wc -l < "$DB_FILE")
    
    if [[ "$del_id" =~ ^[0-9]+$ ]] && [ "$del_id" -le "$total_lines" ] && [ "$del_id" -gt 0 ]; then
        sed -i "${del_id}d" "$DB_FILE"
        apply_rules
    else
        echo -e "${RED}无效的 ID${NC}"
    fi
}

# 5. 恢复/重载配置
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
    echo -e "\n${CYAN}PVE 透明转发管理 (nftables)${NC}"
    if systemctl is-active --quiet nftables; then
        nft_status="${GREEN}● 运行中${NC}"
    else
        nft_status="${RED}● 已停止${NC}"
    fi
	echo -e "服务监控: ${nft_status}${NC}"
    echo "1. 查看所有规则"
    echo "2. 添加转发规则"
    echo "3. 暂停/开启规则"
    echo "4. 删除转发规则"
    echo "5. 恢复/重载配置"
    echo "6. 退出"
    read -p "请输入选项 [1-6]: " choice

    case $choice in
        1) list_rules ;;
        2) add_rule ;;
        3) manage_state ;;
        4) del_rule ;;
        5) restore_config ;;
        6) exit 0 ;;
        *) echo "无效输入" ;;
    esac
done