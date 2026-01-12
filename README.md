# PVE (Proxmox VE) 透明端口转发管理工具 (No-SNAT) -- 端口转发获取真实IP
# PVE Transparent Port Forwarding Manager (No-SNAT) -- Port Forwarding to Obtain a Real IP Address

> **[CN] 中文说明请向下滚动 | [EN] Scroll down for English instructions**

---

## 🇨🇳 [CN] PVE 透明端口转发说明

这是一个专为 **Proxmox VE (基于 Debian 12)** 设计的 Bash 自动化脚本，用于在 PVE 宿主机上快速配置和管理端口转发规则。

### 🎯 解决的痛点

在 PVE 环境中，我们经常需要将宿主机的公网端口转发给内部的虚拟机 (VM) 或容器 (LXC)。使用本工具解决以下问题：

1.  **虚拟机无法获取真实公网 IP**
    * **传统做法**：使用 `iptables MASQUERADE` 或常见的 NAT 脚本，虚拟机会发现所有请求都来自 PVE 网桥 IP (`vmbr0`)，导致无法进行基于 IP 的限流、审计或封禁。
    * **本方案**：只做 DNAT（目标地址转换），**不做 SNAT**。数据包透传至虚拟机，虚拟机能看到真实的公网访客 IP。

2.  **PVE 网络配置繁琐**
    * **痛点**：手写 `nftables` 或 `iptables` 容易出错，且难以管理。
    * **本方案**：提供菜单式操作（增/删/查），自动生成配置文件，并在 PVE 重启后自动生效。

3.  **端口映射管理混乱**
    * **痛点**：运行了十几个容器，过段时间完全忘记宿主机的 `8080` 是转给哪个容器的 Web 服务，还是转给那个 Windows VM 的 RDP？
    * **本方案**：**内置备注功能**，你可以标记每个规则（例如：“LXC_100_Nginx”、“Win11_RDP”）。

4.  **协议支持**
    * **本方案**：支持 TCP、UDP 或 TCP+UDP 双协议一键转发（适合 DNS、游戏服务器等）。

---

### 🛠️ 核心原理与网络要求 (非常重要)

#### 适用场景
* **宿主机 (Host)**: 你的 PVE 服务器，拥有公网 IP。
* **客户机 (Guest)**: PVE 内部的 VM 或 LXC 容器，通常只有内网 IP（如 `10.0.0.x` 或 `192.168.x.x`）。

#### ⚠️ 关键设置：网关指向
由于本脚本**保留了源 IP**，虚拟机收到的数据包源地址是公网 IP。为了让虚拟机能正确回包，**必须满足以下条件：**

**虚拟机的“默认网关 (Gateway)”必须指向 PVE 宿主机的内网 IP (通常是 `vmbr0` 的 IP)。**

如果虚拟机使用其他旁路由（OpenWrt）作为网关，或者网关配置错误，外部连通性将失败。

#### 流量走向示意图
```text
[外部用户] (IP: 1.1.1.1)
    |
    v
[PVE 宿主机] (IP: 公网 / 内网: 192.168.1.1)
    |  <--- 脚本在此处工作 (DNAT: 目标变更为 VM IP)
    |  <--- 保持源 IP 为 1.1.1.1
    v
[虚拟机/LXC] (IP: 192.168.1.100)
    |
    | (回包: 发送给 1.1.1.1)
    | (关键: 必须查路由表，下一跳交给 PVE 192.168.1.1)
    v
[PVE 宿主机] ---> [外部用户] (连接成功)
```

---

### 🚀 使用指南

#### 1. 安装脚本

将 `pve_port_forward_zh.sh` 上传至 PVE Shell。

```bash
chmod +x pve_port_forward_zh.sh

```

#### 2. 运行管理界面

```bash
./pve_port_forward_zh.sh

```

#### 3. 功能说明

* **查看规则**：显示当前所有映射，包含 ID、协议、VM IP 及**备注**。
* **添加规则**：
* 输入 PVE 监听端口。
* 输入 VM/LXC 的真实 IP 和端口。
* 选择协议。
* 输入备注（如：`CT_101_Web`）。


* **删除规则**：根据 ID 删除。

---

### ⚠️ PVE 特别注意事项

1. **防火墙兼容性**：本脚本会接管 `nftables` 的 NAT 表。如果你开启了 PVE 数据中心级别的防火墙功能，请测试兼容性。通常情况下，NAT 规则与 PVE 的 Filter 规则是共存的。
2. **SSH 防断连**：请勿在脚本中随意修改 `INPUT` 链规则（脚本默认允许 INPUT），以免丢失对 PVE 8006 面板或 SSH 的访问。

---

## 🇺🇸 [EN] PVE Transparent Port Forwarding Manager

This is a Bash automation script designed specifically for **Proxmox VE (Debian 12 based)**. It allows you to quickly configure and manage port forwarding rules on the PVE Host.

### 🎯 The Pain Points Solved

In a PVE environment, forwarding public ports from the Host to internal VMs or LXC containers often comes with challenges:

1. **Loss of Client Real IP**
* **Standard Method**: Using `iptables MASQUERADE` creates a SNAT, making all traffic reaching the VM look like it comes from the PVE Host's internal IP (`vmbr0`). This breaks IP-based logging, rate-limiting, or banning.
* **This Solution**: Uses **DNAT only (No SNAT)**. Packets are transparently forwarded to the VM, preserving the original client public IP.


2. **Complex Configuration**
* **Problem**: Managing raw `nftables` or iptables rules manually is error-prone.
* **This Solution**: Provides a simple Menu-Driven Interface (Add/List/Delete), generates config files automatically, and persists across reboots.


3. **Management Chaos**
* **Problem**: Forgetting which host port maps to which VM service (Web? RDP? SSH?) after a few weeks.
* **This Solution**: **Built-in Remarks/Comments**. You can label every rule (e.g., "LXC_100_Nginx", "Win11_RDP").


4. **Protocol Support**
* **This Solution**: One-click support for TCP, UDP, or TCP+UDP (Dual Stack).



---

### 🛠️ Core Principle & Requirements (Crucial)

#### Scenario

* **Host**: Your PVE Server (with Public IP).
* **Guest**: VM or LXC Container inside PVE (Private IP, e.g., `192.168.x.x`).

#### ⚠️ Critical Setup: Gateway

Since this script **preserves the Source IP**, the VM receives packets directly from the Public IP. For the return traffic to find its way back:

**The VM/LXC's "Default Gateway" MUST point to the PVE Host's Internal IP (usually the `vmbr0` IP).**

If your VM uses another router (like an internal OpenWrt VM) as its gateway, connectivity will fail.

#### Traffic Flow Diagram

```text
[Public User] (IP: 1.1.1.1)
    |
    v
[PVE Host] (IP: Public / Internal: 192.168.1.1)
    |  <--- Script Logic (DNAT: Change Dest to VM IP)
    |  <--- Keeps Source IP as 1.1.1.1
    v
[Guest VM/LXC] (IP: 192.168.1.100)
    |
    | (Reply: Send to 1.1.1.1)
    | (CRITICAL: Routing table sends packet to Gateway 192.168.1.1)
    v
[PVE Host] ---> [Public User] (Connection Established)

```

---

### 🚀 Quick Start

#### 1. Install

Upload `pve_port_forward_en.sh` to your PVE Shell.

```bash
chmod +x pve_port_forward_en.sh

```

#### 2. Run

```bash
./pve_port_forward_en.sh

```

#### 3. Features

* **List Rules**: Show all active mappings with IDs, Protocols, VM IPs, and **Remarks**.
* **Add Rule**:
* Input Host listening port.
* Input Guest VM IP and port.
* Select Protocol (TCP / UDP / Both).
* Input Remark (e.g., `CT_101_Web`).


* **Delete Rule**: Remove rules by ID.

---

### ⚠️ PVE Specific Notes

1. **Firewall Compatibility**: This script manages the `nftables` NAT table. If you rely heavily on the PVE GUI Firewall (Data Center level), please test for compatibility. Generally, NAT rules coexist peacefully with PVE Filter rules.
2. **Safety**: The script allows all INPUT traffic by default to prevent locking you out of the PVE Web GUI (8006) or SSH.
