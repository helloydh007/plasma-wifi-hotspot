# Plasma Wi-Fi 热点控制（Plasma Wi-Fi Hotspot Control）

Plasma 6 系统托盘插件 + 后端服务，用来一键开关 Wi-Fi 热点，并支持两种截然不同的模式。

**English documentation: [README.en.md](README.en.md)**（英文简介页，中文为主文档）

![插件界面](docs/screenshot.png)

在 Debian 13 + KDE Plasma 6.3（Intel AX201 / iwlwifi）上开发并实测通过。

## 设计初衷

Windows 的"移动热点"可以**一边连接 Wi-Fi、一边开热点**，同一台机器既能上网又能给手机等设备共享网络；
Linux 桌面原生却没有这个体验——NetworkManager 的热点会顶掉 Wi-Fi 连接。本项目的出发点就是把
Windows 的这个能力带到 Linux：**不插网线、不断 Wi-Fi，照样开热点**。为此实现了并发模式
（hostapd + 虚拟接口 `ap0`，Wi-Fi 客户端保持在线），同时也保留更通用的普通模式
（NetworkManager 原生热点，Wi-Fi 需断开）作为兜底。"热点跟随 Wi-Fi 信道、不强行改动 Wi-Fi"
的信道原则参考了 [linux-wifi-hotspot](https://github.com/lakinduakash/linux-wifi-hotspot)
（create_ap 后端）的成熟做法；受硬件约束的部分见下文"硬件前提与已知限制"。

## 特性

- **两种模式**：并发模式（保持 Wi-Fi 连接）与普通模式（断开 Wi-Fi，网卡整体做 AP）
- **托盘图标**反映状态：运行中是热点图标；**未开启时是"热点原图标 + 红色斜线"（仿静音图标样式）**（不与"断网"图标混淆）；鼠标悬停显示热点状态、频段、信道、客户端数
- **状态自动跟随**：托盘图标/悬浮提示周期刷新（默认 5 秒，右键"配置"可调 2–60 秒），命令行开关、监管脚本自动暂停热点等外部变化也会如实反映
- **双语界面**：跟随系统语言自动切换（KDE 标准 i18n：英文源串 + `po/zh_CN.po`，已编译进插件包）。改了界面文案后跑 `./build-translations.sh` 重新生成翻译即可。注：来自后端脚本的执行结果消息目前仍是中文
- 面板里可切换模式、开关热点、**开机自启**开关
- **修改热点名称与密码**：面板里直接改（运行中的热点会自动重启使新值生效）
- **依赖自检**：逐项检查 hostapd / dnsmasq / iw / iptables / 后端文件 / polkit 授权，缺失时给出可复制的修复命令
- **免密码操作**：polkit 规则只授权执行一个控制脚本（见下"安全"）
- 另有**桌面入口**：应用菜单/KRunner 搜"Wi-Fi 热点控制"可打开独立窗口

## 两种模式

| | 并发模式 | 普通模式 |
|---|---|---|
| Wi-Fi 客户端 | **保持连接**（网速不受影响） | **必须断开**（这是该模式的定义） |
| 实现 | hostapd + 虚拟 `ap0` + dnsmasq + iptables NAT | NetworkManager 原生热点（`ipv4.method shared`，自动 DHCP/NAT） |
| 频段 | **跟随 Wi-Fi 当前信道**（2.4G→hw_mode g / 5G→a）；固件拒绝 5G 时自动回退 2.4G 并在关闭热点时恢复频段偏好 | 2.4GHz（ch6） |
| 上行 | 当前 Wi-Fi 连接 | 默认路由设备（例如有线网卡）；没有上行时仅局域网 |

为什么并发模式限制这么多：见下一节。**5GHz 热点在这块网卡上两种模式都不可用**（实测）。

## 硬件前提与已知限制（实测结论）

在 Intel AX201 + `iwlwifi` 上实测得到的三条硬约束：

1. **5GHz 无法做 AP（本机固件限制，非原理限制）**。iwlwifi 的监管域是 *self-managed*（LAR，位置感知监管），5GHz 全部标记为 `NO-IR`（禁止发信标），用户态 `iw reg set` 改不动它——实测 hostapd 报 "Hardware does not support configured channel"。因此并发模式**优先跟随 Wi-Fi 当前信道**（含 5GHz，在支持的网卡上直接可用），被固件拒绝时才自动把 Wi-Fi 降到 2.4GHz（关闭热点时恢复频段偏好；配置 `FALLBACK_2G=no` 可禁止降级）。想在 Intel 上解锁真正的 5GHz 并发热点：上游 [linux-wifi-hotspot](https://github.com/lakinduakash/linux-wifi-hotspot) 提供的 [iwlwifi-lar-disable](https://github.com/lakinduakash/linux-wifi-hotspot/tree/master/util/iwlwifi-lar-disable) 工具（DKMS 给 iwlmvm 加回 `lar_disable=1` 参数）装好后，本项目的并发模式无需任何改动即可在 5GHz 工作。**实测补充（本机 AX201 + ucode 89.4d42c933）**：装上补丁后监管解锁成功、hostapd 能尝试 ch40，但固件在"5G 并发 AP+STA"时直接崩溃（`Microcode SW error detected` / `NMI_INTERRUPT_UMAC_FATAL`）——即这张卡的固件本身不支持 5G 并发，监督脚本会自动回退 2.4G，补丁模块已卸载还原（构建产物保留在 `/var/lib/linux-wifi-hotspot/lar/`，未来固件修复后一条命令可重装）。换 5G AP 友好的网卡（如 MediaTek mt7921au USB 卡）即可直接并发。
2. **STA 与 AP 必须同信道**。驱动的接口组合限制是 `#{ managed } <= 1, #{ AP, ... } <= 1, #channels <= 1`：允许"客户端 + AP 同时存在"，但只能在同一信道上时分复用。这正是"热点跟随 Wi-Fi 信道"的原因——客户端换信道/断开时，监督脚本会停掉热点并在新信道上重建。
3. **NetworkManager 自带的热点功能会把客户端连接顶掉**（它把整块网卡从 managed 切成 AP，属于单模式）。所以并发模式不能走 NM，必须用 hostapd 在虚拟接口上自己发信标——这也是本项目的核心。

> 顺带解释了"为什么 Windows 可以一边连 Wi-Fi 一边开热点"：Windows 的移动热点走 Wi-Fi Direct（P2P-GO），而这张卡的组合规则里 P2P-GO 允许 `#channels <= 2`，可以跨信道；Linux 的 AP 模式没有这条路。

## 依赖

**系统环境**（Plasma 桌面自带，无需额外安装）：

| 组件 | 说明 |
|---|---|
| KDE Plasma 6 + Qt6 | 插件用 Plasma 6 API（6.3 上开发测试；**Plasma 5 不兼容**） |
| `kpackagetool6` | 插件安装工具，Plasma 桌面自带 |
| `org.kde.plasma.plasma5support` | 插件的 executable 数据引擎，Plasma 桌面自带 |
| NetworkManager + `nmcli` | Wi-Fi 管理；"普通模式"热点由 NM 实现 |
| polkit / pkexec | 免密码授权体系 |
| systemd | 后端服务（并发热点 + 普通模式自启） |

**需要安装的系统包**（`iw`、`iptables` 通常已随系统自带，缺哪个装哪个）：

```bash
sudo apt install hostapd dnsmasq iw iptables
```

装不装都不影响插件运行——面板里有**依赖自检**，缺什么会列出来并给出可复制的安装命令，装好点"重新检查"即可。

**硬件**：

- 一块支持 AP 模式的网卡（`iw list` 的 "Supported interface modes" 里有 `AP` 即可；Intel AX201 实测可用）
- **并发模式**额外要求驱动允许"客户端 + AP"接口组合，且两者必须**同信道**（2.4GHz）——详见下文"硬件前提与已知限制"

## 安装

```bash
sudo apt install hostapd dnsmasq iw iptables    # 缺哪个装哪个
git clone <此仓库> && cd plasma-wifi-hotspot
bash install.sh
```

`install.sh` 一次做完四件事：

1. **部署后端**（pkexec，会弹一次授权框）：控制脚本、systemd 单元、polkit 动作与规则、NM 的 `ap0` unmanaged 配置
2. 安装 **Plasma 插件**（用户级 `~/.local/share/plasma/plasmoids/`，不需要 root）
3. 安装**桌面入口**（应用菜单/KRunner 可搜"Wi-Fi 热点控制"）
4. **刷新界面**：插件内容变化时才重启 plasmashell（见下"更新"一节）

装完两步收尾：

1. 编辑 `/etc/kde-hotspot/config`（权限 600），把 `SSID` / `PASS` 改成你自己的。
   **未设置时后端拒绝启动热点**，不会用默认密码起热点。
2. 把插件放进托盘：右键面板 → 系统托盘设置 → 条目 → 勾选"Wi-Fi 热点控制"；
   或者直接拖到面板上（放在面板上会额外显示频段/信道文字，托盘里只显示图标）。

## 更新

```bash
git pull
bash install.sh               # 只在插件内容变化时才重启 plasmashell
bash install.sh --no-restart  # 从不重启（新界面在注销重登后生效）
```

**关于 plasmashell 重启（重要）**：plasmashell 把插件 QML 读进内存，更新插件后**必须重启 plasmashell**（或注销重登）才会加载新界面
（表现为：图标没变、面板里看不到新加的选项）。但重启会重建**所有**小组件，只在内存里保存的开关会复位——
例如电池小程序的"阻止睡眠/咖啡因"、第三方插件未持久化的状态。

因此 `install.sh` 只会在**插件内容确实变化时**才重启：它对 QML/元数据/配置/翻译取指纹并与上次安装比较，
仅后端改动（脚本、systemd 单元、polkit 规则）不会触发重启。需要绝对不重启时用 `--no-restart`。

> 想要一个不受 plasmashell 重启影响的"保持唤醒"：`systemd-inhibit --what=idle:sleep --why="手动保持唤醒" sleep infinity &`
> （结束时 kill 该进程），它由独立进程持有抑制锁。

## 使用

- 点托盘图标 → 面板：状态、开/关、模式单选、开机自启、依赖自检
- **开**：并发模式下会自动把 Wi-Fi 切到 2.4GHz 并起草热点；普通模式下会先断开 Wi-Fi 再起 AP（面板上有明确提示）
- **关**：并发模式下会停热点并把 Wi-Fi 的频段偏好恢复成关闭前的值（通常回 5GHz）
- 右键托盘图标 → "配置 Wi-Fi 热点控制…"：设置显示标签、刷新间隔

### 桌面入口怎么打开

安装脚本会在 `~/.local/share/applications/` 放一个桌面入口，三种打开方式：

1. **应用菜单**：打开开始菜单，在"网络"分类里找 **Wi-Fi 热点控制**（KRunner 里按 Alt+Space 搜"热点"也行）
2. 命令行：`gtk-launch org.kde.hotspot`
3. 直接跑：`plasmawindowed org.kde.hotspot`

打开的就是插件面板的独立窗口（和托盘弹出的是同一套界面）。想放到桌面或面板上做快捷方式：把这个 `.desktop` 文件复制到 `~/Desktop/` 或拖到面板即可。

命令行等价物（无需 sudo，polkit 已授权）：

```bash
pkexec /usr/local/sbin/kde-hotspot-ctl status          # 状态 JSON
pkexec /usr/local/sbin/kde-hotspot-ctl on|off          # 按当前模式开关
pkexec /usr/local/sbin/kde-hotspot-ctl mode concurrent|normal
pkexec /usr/local/sbin/kde-hotspot-ctl autostart on|off
pkexec /usr/local/sbin/kde-hotspot-ctl set-credentials <SSID> [<新密码>]
```

动作类命令会在 stdout 输出一行 JSON（`{"ok":true,"message":"…"}`），人类可读日志走 stderr——
插件就是据此判断成败的（不依赖 exitCode 的类型）。

## 架构

```
[ Plasma 插件（用户） ] --pkexec(免密码)--> [ kde-hotspot-ctl（root） ]
        |                                            |
        +-- 只读状态：直接跑 iw/nmcli/systemctl        +-- 两套热点机制的启停与互斥
            （不需要特权）                              +-- nmcli 切频段 / NM 热点
                                                       +-- systemctl start|stop|enable|disable
```

| 文件 | 作用 |
|---|---|
| `plasmoid/` | Plasma 6 插件包（`kpackagetool6 -t Plasma/Applet -i plasmoid`） |
| `backend/kde-hotspot-ctl` | **唯一的特权入口**：on/off/mode/autostart/set-credentials/status |
| `backend/kde-hotspot.sh` | 并发模式监督循环：跟随 Wi-Fi 信道起停 hostapd；遵守"保持关闭"标记 |
| `backend/kde-hotspot{,-dhcp,-normal}.service` | systemd 单元（后者是普通模式的开机自启） |
| `backend/org.kde.hotspotctl.policy` + `49-kde-hotspot.rules` | polkit 动作与规则 |
| `sync-backend.sh` | 把 `backend/` 同步进插件包（两处必须一致；改完 backend 记得跑一次） |
| `backend/deploy.sh` | 部署后端（root）；插件包内也带一份（`plasmoid/contents/backend/`），供插件内"一键修复"使用 |
| `backend/org.kde.hotspot.desktop` | 桌面入口（`plasmawindowed org.kde.hotspot`） |

## 安全

- polkit 授权**只作用于 `/usr/local/sbin/kde-hotspot-ctl` 这一个脚本**（动作带 `org.freedesktop.policykit.exec.path` 注解），不能拿来执行任意命令。删除 `/etc/polkit-1/rules.d/49-kde-hotspot.rules` 即恢复成"每次弹密码"。
- **包安装刻意不在免密范围内**：否则等于"任何用户进程都能免密装包"。所以插件里的依赖修复给的是可复制的命令。
- **只读状态查询不经过 pkexec**：插件的状态轮询以普通用户身份运行 `kde-hotspot-ctl status`（只用 iw/nmcli/systemctl 只读查询 + 读配置/状态标记）。这样每次轮询不会 fork root 进程、不建立 polkit/PAM 会话（曾经每秒一次，约 8.6 万次/天）。需要特权的操作（on/off/mode/autostart/set-credentials）仍然走 `pkexec`。轮询间隔在插件配置里以**秒**为单位（默认 5，可调 2–60）。
- 热点密码保存在 `/etc/kde-hotspot/config`（`root:netdev 640`，仅 root 与网络管理组可读）。这个用户集合与 polkit 规则授权的集合（sudo/netdev 组免密执行 ctl）一致，因此不降低安全等级；它让插件免特权读到 SSID/密码/MODE。脚本不内置任何默认密码，配置缺失时拒绝启动。
  `status` 的 JSON 里包含当前热点名称与密码（面板"当前密码"行默认打码，点眼睛图标显示）——多人共用的机器上如不接受，删掉 `do_status` 里的 `pass` 字段即可。
- 无敏感信息的状态标记（`disabled`、`fallback`）为 644，供免特权状态查询读取；`/run/kde-hotspot/hostapd.conf`（含密码）保持 600。
- 后端服务以 root 运行是必需的（hostapd/dnsmasq/iptables 都需要特权）。

## 卸载

> 建议：如果热点正开着，先在插件里点一次"**关闭热点**"（并发模式会借此把 Wi-Fi 频段偏好恢复成 5GHz），再执行下面的命令——最后一步删除的状态目录里存着频段备份，先关再删最稳妥。

```bash
# 1) 停止并禁用后端服务（热点开着的话会一并停掉）
sudo systemctl disable --now kde-hotspot kde-hotspot-dhcp kde-hotspot-normal

# 2) 删除后端文件（控制脚本、systemd 单元、polkit、NM 的 ap0 配置）
sudo rm -f /etc/systemd/system/kde-hotspot.service \
           /etc/systemd/system/kde-hotspot-dhcp.service \
           /etc/systemd/system/kde-hotspot-normal.service \
           /usr/local/sbin/kde-hotspot-ctl \
           /usr/local/sbin/kde-hotspot.sh \
           /usr/share/polkit-1/actions/org.kde.hotspotctl.policy \
           /etc/polkit-1/rules.d/49-kde-hotspot.rules \
           /etc/NetworkManager/conf.d/99-kde-hotspot-ap0.conf
sudo rm -rf /etc/kde-hotspot /var/lib/kde-hotspot
sudo systemctl daemon-reload && sudo nmcli general reload

# 3) 清理可能残留的虚拟接口与普通模式 NM profile（不存在会自动跳过）
sudo ip link delete ap0 2>/dev/null || true
nmcli connection delete kde-hotspot-normal 2>/dev/null || true

# 4) 先从托盘移除小组件（右键托盘图标 → 移除，或“系统托盘设置 → 条目”里取消勾选），
#    再卸载插件——这样不必重启 plasmashell（重启会复位电池小程序的“阻止睡眠/咖啡因”等
#    只存在于内存里的开关）
kpackagetool6 -t Plasma/Applet -r org.kde.hotspot
rm -f ~/.local/share/applications/org.kde.hotspot.desktop
# 若已卸载但托盘仍残留失效图标，再执行：
# systemctl --user restart plasma-plasmashell
```

说明：

- `/var/lib/kde-hotspot` 里只有状态标记和频段备份（无密码）；`/etc/kde-hotspot/config` 里存着热点名称/密码（600），删掉即彻底清除
- 只想卸插件、保留后端（继续用命令行 `pkexec …/kde-hotspot-ctl` 控制）的话，只执行第 4 步即可
- polkit 规则删除后即恢复默认行为：任何 `pkexec` 调用重新弹密码

## 常见问题

### 手机连上了热点，但提示"无法上网"

软件层面有两类常见原因，本项目都已自动处理，一般不需要手工介入：

| 场景 | 现象与根因 | 自动处理 |
|---|---|---|
| **Docker 等软件重启** | 它们会把 `FORWARD` 链策略设为 DROP 并清掉链上的第三方规则 → 客户端能连上、拿到 IP，但所有流量被丢弃 | 监督脚本每约 3 秒补检转发/NAT 规则，缺了就补回 |
| **代理软件 TUN 模式**（Clash Verge / mihomo / sing-box 等） | 它们插入 9000 段的策略路由，把流量导向自己的 TUN 并屏蔽默认路由 → 客户端的转发包"Network is unreachable"被内核静默丢弃（`IpOutNoRoutes` 增长） | 自动为热点网段插入更高优先级的规则（`from 10.233.33.0/24 lookup main`，优先级 8990，可用 `RULE_PRIO` 调整），让客户端流量绕开代理直连上行 |

排查命令（都以 root 运行）：

```bash
nstat -az | grep -iE 'noroute|drop'        # 内核是否有"无路由/丢弃"计数
ip rule show                               # 是否有代理插入的 9000 段策略路由
ip route get 223.5.5.5 from 10.233.33.50 iif ap0   # 模拟客户端转发时的路由解析
sudo tcpdump -ni ap0 host 10.233.33.50     # 客户端到底发了什么
```

如果客户端流量确实发出去了却收不到回包，问题在更上游（路由器/运营商），与热点无关。

## 参考与致谢

- **[linux-wifi-hotspot](https://github.com/lakinduakash/linux-wifi-hotspot)**（lakinduakash）——本项目并发模式的信道原则即搬迁自它的 create_ap 后端："热点跟随 Wi-Fi 客户端当前信道、不改动 STA 的频段"。它提供的 [iwlwifi-lar-disable](https://github.com/lakinduakash/linux-wifi-hotspot/tree/master/util/iwlwifi-lar-disable) 工具（DKMS 给 iwlmvm 加回 `lar_disable=1`）也是在 Intel 网卡上解锁 5GHz 并发热点的参考方案
- **[oblique/create_ap](https://github.com/oblique/create_ap)** —— 上述后端的原始上游，hostapd + dnsmasq + iptables 这套经典组合的出处
- **[KDE plasma-nm](https://github.com/KDE/plasma-nm)** —— 本项目"普通模式"使用的 NetworkManager 原生热点能力即来自 plasma-nm 所管理的 NM

## English summary

A Plasma 6 system-tray applet + root backend to toggle a Wi-Fi hotspot, in two modes:
**concurrent** (hostapd on a virtual `ap0`, the Wi-Fi client stays connected — same-channel only)
and **normal** (NetworkManager AP mode, which necessarily drops the Wi-Fi client).
Tested on Debian 13 / Plasma 6.3 / Intel AX201: 5 GHz AP is impossible on this chipset
(self-managed regulatory domain marks 5 GHz as no-IR), and STA+AP concurrency requires the
same channel. Install with `bash install.sh` (see 安装 above; dependencies: hostapd, dnsmasq,
iw, iptables on top of a stock Plasma 6 desktop). To uninstall, follow the 卸载 section —
it removes the backend, polkit rules, plasmoid and desktop entry.

## 许可

GPL-2.0-or-later（见 `LICENSE`）。
