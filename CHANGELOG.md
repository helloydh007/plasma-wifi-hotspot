# 变更记录

本项目遵循语义化版本。中文为主，条目按"安全 / 修复 / 改进 / 测试 / 文档"归类。

## 1.1.0

按三份代码评审报告（DeepSeek / GPT / Qwen）逐条核对后的修复版本。
**每条结论都先在真实代码上验证过**：报告说对的就改，说不准或不对的在下文"经核实不予修改"里说明理由。

### 安全

- **配置文件不再被 `source` 执行**（P0）。旧实现 `kde-hotspot-ctl` 以 root `. "$CONF"` 读配置：
  配置里的 `$(命令)`、反引号会被 root 执行（本地提权），`$$` 会被展开成进程号、
  `$(...)` 会被求值——既能让热点名/密码被悄悄改写，也能直接执行任意命令。
  现在新增 `backend/kde-hotspot-config.sh`：纯数据解析（`KEY=value` + 注释），解析、校验、**原子写回**一体，
  绝不 `source`；白名单键之外的键忽略；写回时只重写被改的行（保留行尾注释），
  值里 `[A-Za-z0-9._:/@%+,-]` 之外的字符用单引号包起来。旧格式（未加引号、带行尾注释）继续可读。
  `hs_conf_get` / `hs_conf_load` / `hs_conf_set` 三者语义统一：同一键重复时以最后一次为准
  （等同旧 `source` 行为），写回时把重复行合并成一行。
- **`--pass-file` 不再能读任意文件**（P0）。以前只检查"文件是否可读"，配合 polkit 免密授权等于
  "让 root 把任意文件内容写进配置/回显出来"（例如 `/etc/shadow`）。现在要求：普通文件（非符号链接）、
  属主为调用者（`PKEXEC_UID`）、权限不含组/他人位、不超过 4 KiB、所在目录属于调用者且组/他人不可写；
  读完立即删除文件并尽量删掉临时目录。不合规一律拒绝并说明原因。
- **临时密码文件不再用可预测路径**（P0）。插件改用 `mktemp -d` 在 `$XDG_RUNTIME_DIR` 下建随机目录 +
  `umask 077`，失败路径也会清理；读取端只接受"属主是我、目录不可被他人写"的文件，符号链接攻击无效。
- **polkit 组与配置文件组不再错位**。`deploy.sh` 从 `netdev`/`sudo`/`wheel` 里选调用者实际所属的第一个组，
  同一结果写入 polkit 规则、配置文件属组与 `/var/lib/kde-hotspot/conf.group`；ctl 改配置时沿用该组。
- **systemd 单元加固**。主服务与 normal 单元的能力集从"网络管理 + 文件相关一堆能力"收窄到
  `CAP_NET_ADMIN`/`CAP_NET_RAW`（dnsmasq 按它自己声明需要的 5 项保留），并补上
  `ProtectKernel*`/`ProtectClock`/`ProtectHostname`/`RestrictNamespaces`/`LockPersonality`/
  `SystemCallArchitectures=native`/`RestrictAddressFamilies`/`UMask=0077`。
  `systemd-analyze security` 分数：主服务 6.8 → **4.4（OK）**，dnsmasq 6.7 → **5.0**。

### 修复

- **"取消"按钮无效**（P0）。开启热点后 15 秒内面板停在"开启中"，此时按钮仍是"开启"，
  点下去只会重复发开启指令。现在"开启中"状态下点击即发送 `off`（取消），并按后端是否受理给出反馈。
- **`off` 不再只是"停一次"**：以前 `off` 只停服务，重启/插拔网卡/NM 重连可能又把热点拉起来。
  现在 `off` = 停两套机制 + 关闭开机自启 + 写"保持关闭"标记；`autostart on` 会清掉该标记。
- **切换模式只关一半**：`mode` 以前只 disable 当前模式的单元，另一个模式的单元仍是 enabled。
  现在切换模式 = 停两套机制 + 三个单元全部 disable + 关自启，并如实告知用户。
- **普通模式 `off` 语义不对称**：以前不会删除 `autostart-normal` 标记，重启后热点又回来。现已统一。
- **`status` 的 JSON 转义不全**（控制字符会直接破坏 JSON）。补上 `\b\f` 与 `[[:cntrl:]] → \u00xx`，
  面板不再因为密码/SSID 里有奇怪字符而整块状态解析失败。
- **DHCP 静默失败**：主服务起来了但 dnsmasq 没起来时，`do_on` 只检查主服务，面板显示"运行中"，
  客户端连得上却拿不到 IP。现在 `on` 会检查 DHCP 单元并在失败时明确报错，`status` 增加 `dhcp_active`，
  面板对 `dhcp_active=no` 显示警告横幅。
- **改凭据不重启"待命中"的服务**：并发服务正在运行但还没发出信标时，改密码只写了配置、热点仍用旧密码。
  现在只要 `kde-hotspot.service` 处于 active 就重启它。
- **普通模式会复用旧的 NM profile**：SSID/密码改了以后仍用旧 profile 起来。现在比对 profile 里的
  SSID/PSK，不一致就删掉重建。
- **残留 iptables/策略路由**：清理规则时按"当前配置"推算接口/网段，改了 `STA_IF`/`AP_IP` 后就拆不干净。
  现在监督脚本把 `STA_IF AP_IF AP_NET` 写进 `/run/kde-hotspot/rules.state`，`cleanup`/停服务按**记录**拆规则，
  再按当前配置补拆一遍。
- **`AP_NET` 不再硬编 `/24`**：网段由 `AP_IP` 派生（`hs_derive_ap_net`），`AP_NET` 与 `AP_IP` 不一致时告警。
- **`COUNTRY` 不再默认 `CN`**：默认沿用当前监管域，避免无谓地改写用户所在地区的监管设置。
- **客户端数不再数租约文件**：改为读 hostapd 的 station dump（监督脚本每约 6 秒写 `$STATE/clients`），
  普通模式退回 `ARP`（只数 `Flags=0x2` 的表项），不再依赖发行版各异的
  `/var/lib/misc/dnsmasq.leases`。
- **`deploy.sh` 写配置不再有 644 窗口**：以前先 `install -m 644` 再 `chmod 640`，中间瞬间任何人都能读到密码；
  现在直接 `install -m 640`，并在非 root 场景保留原权限。
- **`CompactRepresentation` 的标签逻辑不可达**：`Plasmoid.formFactor` 在面板里是 `Horizontal`/`Vertical`，
  不是 `Planar`。现在按 `formFactor === Vertical || containmentType & CustomEmbeddedContainment ||
  containmentDisplayHints & ContainmentForcesSquarePlasmoids` 判断是否方形化，托盘里不再出现半截文字。

### 改进

- 依赖自检增加配置文件库 `/usr/local/lib/kde-hotspot/config.sh`（缺失时会明确报出来）。
- 监督脚本启动时读一次配置（文档已注明"改完要重启服务"），循环里不再反复解析文件；
  状态轮询仍为免特权只读路径。
- 插件默认显示标签（`showLabel=true`）、轮询默认 5 秒（可调 2–60）。
- `README` 补充：配置文件格式与"绝不执行"的保证、`--pass-file` 的接受条件、`off`/`autostart`/`mode` 的语义、
  DHCP 失败与"配置读一次"两个常见问题、开发与测试章节。

### 测试与 CI

- `tests/test-config.sh`：配置库单测扩到 **65 项**（新增同一键重复的读/写一致性）。
- `tests/test-ctl.sh`（新增）：控制脚本**端到端**测试 **108+ 项**。做法是把 ctl 里的绝对路径声明 sed 到临时目录，
  用 mock 的 `iw`/`nmcli`/`systemctl`/`ip`/`iptables` 跑出真实命令序列，再断言 JSON、状态文件与系统调用。
  不需要 root、不需要网卡、不碰真实网络。覆盖：配置注入不执行、JSON 转义、客户端计数、
  `off`/`autostart`/`mode` 语义、`--pass-file` 的 5 种拒绝场景与 1 种接受场景、改凭据重启待命服务、
  按记录拆规则、DHCP 失败上报、退出码。
- `tests/run-all.sh`（新增）：语法 + shellcheck + 两个测试套件 + 后端副本一致性 + `qmllint` 语法，一条命令跑完。
- `.github/workflows/ci.yml`（新增）：push/PR 跑上述检查；QML 用 `qmllint` 做语法检查
  （CI 装不齐 Plasma 的 QML 模块，import 相关警告忽略，只拦语法错误）。
- `sync-backend.sh --check`：backend 与插件包内副本必须逐字节一致，CI 里会拦。
- 红-绿自检：同一批断言跑在修复前的实现上是 **63 通过 / 45 失败**；修复前的实现里
  配置里的 `$(command)` 会真的被执行、`SSID=My$$Net` 会变成 `My41Net`、带控制字符的 `status` 不是合法 JSON。

### 经核实不予修改（报告结论不成立或超出范围）

- **"dnsmasq 与 systemd-resolved 抢 53 端口"**：不成立。dnsmasq 用 `bind-dynamic` 只绑 `ap0`，
  与 resolved 的 `127.0.0.53` 不冲突，无需停 resolved。
- **"删掉插件包内的后端副本，只留一份"**：不采纳。KDE Store 安装的包必须自带后端才能"一键修复"，
  两份必须一致的问题改用 `sync-backend.sh --check` + CI 拦住，而不是删掉其中一份。
- **"`install.sh` 总是重启 plasmashell"**：早已按内容哈希判断，未变化时不重启。
- **"关闭热点会丢频段备份"**：已有 `$STATE/band.backup` + 陷阱 + `ExecStopPost` 三重保障，且清理时按记录拆规则。
- **IPv6/前缀委派、把后端重构成 D-Bus 常驻服务**：超出本次评审范围，且与"稳定可用"的现状相比收益不明，暂不做。

## 1.0.0

首个发布版本：并发模式（hostapd + 虚拟 `ap0`，跟随 Wi-Fi 信道，5GHz 被固件拒绝时自动回退 2.4GHz）
与普通模式（NetworkManager 原生热点）；Plasma 6 托盘插件 + 桌面入口；polkit 免密授权；
依赖自检与一键修复命令；中英双语界面。
