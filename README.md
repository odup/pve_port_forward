# PVE/Debian Nftables Transparent Port Forwarding Manager

# PVE/Debian Nftables 透明端口转发管理脚本

This script provides a menu-driven interface to manage `nftables` port forwarding rules on Proxmox VE (or Debian). It is designed to be **transparent**, meaning it preserves the original client source IP address when forwarding traffic to backend VMs/Containers.

本脚本提供了一个基于菜单的界面，用于在 Proxmox VE (或 Debian) 上管理 `nftables` 端口转发规则。其设计核心为**透明转发**，即在将流量转发到后端虚拟机/容器时，能够**保留客户端的原始源 IP 地址**。

---

## 🇨🇳 中文说明 (Chinese)

### 💡 为什么使用此脚本？(解决的痛点)

1. **解决“源 IP 丢失”问题(端口转发获取 源IP/真实IP)**：
* **传统痛点**：普通的 NAT/端口转发（如 PVE 自带的防火墙或简单的 iptables SNAT）通常会将流量伪装成宿主机的 IP。这意味着后端应用（如 Nginx、Web 服务、游戏服）的日志里只能看到宿主机的内网 IP，无法获取访问者的真实 IP，导致无法进行基于 IP 的风控或统计。
* **本脚本方案**：使用 DNAT 模式而不做 SNAT，数据包携带原始 IP 直达后端，彻底解决此问题。


2. **告别“管理混乱”**：
* **传统痛点**：手动修改 `/etc/network/interfaces`、`iptables` 命令或分散的配置文件非常容易出错，时间久了很难记住开了哪些端口，甚至导致规则冲突。
* **本脚本方案**：通过统一的数据库文件管理，提供可视化的列表视图，自动排查端口冲突，增删改查一目了然。

### 📌 功能特点

* **保留源 IP (核心功能)**：不做 SNAT (Masquerade)，后端服务可以直接获取访问者的真实 IP，而非宿主机的 IP。
* **交互式菜单**：无需手动编辑配置文件，通过数字菜单即可完成增、删、改、查。
* **协议支持**：支持 TCP、UDP 或 TCP+UDP 同时转发。
* **安全白名单**：支持为每一条转发规则单独设置允许访问的源 IP（支持单 IP 或网段）。
* **状态管理**：支持“暂停”和“开启”规则，无需删除即可临时禁用。
* **冲突检测**：自动检测端口和协议冲突，防止配置错误。
* **自动备份与回滚**：添加规则前自动备份，应用失败自动回滚，降低断网风险。

### 🛠️ 环境要求

* **测试系统**：pve-manager/9.1.1/42db4a6cf33dac83 (running kernel: 6.17.2-1-pve)。
* **权限**：必须以 `root` 用户或使用 `sudo` 运行。
* **依赖**：`nftables` (PVE 默认已安装)。

### 🚀 快速开始

1. **下载/创建脚本**
将脚本内容保存为 `nat_manager.sh`。
2. **赋予执行权限**
```bash
chmod +x nat_manager.sh
```

3. **运行脚本**
```bash
./nat_manager.sh
```


### ⚠️ 关键注意事项 (必读)

#### 1. 虚拟机网关设置 (至关重要！)
由于本脚本采用**透明转发**（不执行 SNAT/伪装），数据包到达后端虚拟机时，源 IP 仍然是外部客户端的 IP（例如 `1.2.3.4`）。

为了让后端虚拟机能正确将回包发送给客户端，**您必须将虚拟机的网关设置为宿主机的内部 IP**。

##### 设置步骤：

1. **宿主机配置**：
假设宿主机的 `vmbr0` (或您使用的桥接网卡) IP 地址为 `192.168.1.1`。
2. **虚拟机/容器配置**：
在虚拟机的网络设置中，将 **网关 (Gateway)** 设置为 `192.168.1.1` (即宿主机的 IP)。
* *如果虚拟机网关指向了路由器的 IP（如 192.168.1.254），转发将失败，因为回包会走路由器而不是回到宿主机。*

#### 2. 防火墙与端口封禁 (特别提示)

* **绕过宿主机 Input 防火墙**：本脚本配置的端口转发发生在网络层的 `Prerouting` 阶段，优先于宿主机的 `Input` 链。
* **这意味着**：即使您在宿主机的防火墙（如 UFW 或 PVE 数据中心防火墙的 Input 规则）中封禁了某个端口（例如 8080），只要通过本脚本配置了 8080 的转发，**流量依然会被转发到后端**，因为流量根本没有进入宿主机的“本地输入”流程。
* **安全建议**：如果您需要限制访问，请直接在脚本添加规则时使用 **“源 IP 白名单”** 功能。


### 📂 文件说明

* `/etc/nat_rules.db`: 规则数据库文件（文本格式，可备份）。
* `/etc/nftables.conf`: 脚本生成的实际 nftables 配置文件（**注意：手动修改此文件会被脚本覆盖**）。

---

## 🇺🇸 English Instructions

### 💡 Why use this script? (Pain Points Solved)

1. **Solves the "Lost Source IP" Issue(Port Forwarding to Obtain Source IP/Real IP)**:
* **The Problem**: Standard NAT/Port Forwarding (like default PVE firewall or simple iptables SNAT) usually masks the traffic as coming from the Host's internal IP. Backend applications (Nginx, Game Servers, etc.) cannot see the real client IP, making IP-based logging, banning, or analytics impossible.
* **The Solution**: This script uses DNAT without SNAT. Packets arrive at the backend carrying the original client IP.


2. **Eliminates Management Chaos**:
* **The Problem**: Manually editing network interfaces, raw iptables commands, or scattered config files is error-prone. It's easy to forget which ports are open or cause rule conflicts.
* **The Solution**: Uses a unified database file with a visual list view. It automatically detects port conflicts and makes management (Add/Delete/Pause) simple and organized.

### 📌 Features

* **Preserve Source IP (Core)**: Does not perform SNAT (Masquerade). Backend services see the real client IP, not the host's IP.
* **Interactive Menu**: Manage rules (Add, List, Pause, Delete) via a CLI menu without editing config files manually.
* **Protocol Support**: Supports TCP, UDP, or both simultaneously.
* **Access Whitelist**: Define allowed source IPs (single IP or CIDR subnet) for each forwarding rule.
* **State Management**: Pause and enable rules without deleting them.
* **Conflict Detection**: Prevents port and protocol conflicts automatically.
* **Auto Backup & Rollback**: Backs up configuration before adding rules and rolls back automatically if application fails.

### 🛠️ Prerequisites

* **Testing System**: pve-manager/9.1.1/42db4a6cf33dac83 (running kernel: 6.17.2-1-pve).
* **Privileges**: Must be run as `root` or via `sudo`.
* **Dependency**: `nftables` (Default on PVE).

### 🚀 Quick Start

1. **Download/Create Script**
Save the script content as `nat_manager.sh`.
2. **Make Executable**
```bash
chmod +x nat_manager.sh
```

3. **Run Script**
```bash
./nat_manager.sh
```


### ⚠️ Important Notes (Must Read)

#### 1. VM Gateway Configuration (Critical!)
Because this script uses **Transparent Forwarding** (No SNAT/Masquerade), packets arrive at the backend VM with the original external client IP (e.g., `1.2.3.4`).

For the backend VM to send the return traffic back to the client correctly, **you must set the VM's Default Gateway to the Host's IP address.**

##### Configuration Steps:

1. **Host Configuration**:
Assume your Host's bridge interface (e.g., `vmbr0`) IP is `192.168.1.1`.
2. **VM/Container Configuration**:
In the network settings of your VM or Container, set the **Gateway** to `192.168.1.1` (The Host's IP).
* *If the VM's gateway is set to your physical router (e.g., 192.168.1.254), forwarding will fail because return packets will bypass the host.*

#### 2. Firewall Behavior (Tip)

* **Bypasses Host Input Firewall**: The port forwarding configured by this script happens at the `Prerouting` stage, which occurs *before* the Host's `Input` chain.
* **Implication**: Even if you block a port (e.g., 8080) on the Host's local firewall (like UFW or PVE Input rules), traffic will **still be forwarded** if a rule exists in this script. The traffic is redirected before the Host's local firewall can drop it.
* **Security Advice**: To restrict access, please use the **"Source IP Whitelist"** feature provided within the script when adding a rule.


### 📂 File Structure

* `/etc/nat_rules.db`: The rules database (Text format, easy to backup).
* `/etc/nftables.conf`: The actual configuration file generated by the script (**Note: Manual edits to this file will be overwritten by the script**).