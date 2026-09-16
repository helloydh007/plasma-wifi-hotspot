# 变更记录

本项目遵循语义化版本。中文为主，条目按"安全 / 修复 / 改进 / 测试 / 文档"归类。

## 1.1.1

实机故障修复 + 一处设计纠正。

### 修复（2026-09-16 实机：点"开启"失败、图标却显示已开启）

- **监督脚本 87ms 就退出**：`kde-hotspot.sh` 在 `hs_conf_load` **之前**设的
  `RULE_PRIO=${RULE_PRIO:-8990}` 会被 load 清掉（load 会先 unset 所有白名单键再只装
  文件里有的键），配置里没写 `RULE_PRIO` 时 → `set -u` 下"未绑定变量" → 脚本退出 →
  systemd 重试 5 次后失败。修法：可选键默认值收进配置库（`HS_KEY_DEFAULTS` +
  `hs_conf_apply_defaults`），由 `hs_conf_load` 统一补上。
- **失败被报成成功**：`systemctl is-active` 对 `Restart=on-failure` 崩溃后
  `activating/auto-restart` 的单元也返回 0。`on` 现在等 `ActiveState+SubState` 真正
  `active/running`（最多 10 秒），失败时把真实状态报给面板；`status` 增加
  `concurrent_service_state` / `normal_service_state`。
- **托盘图标说谎**：图标斜线以前只看 `disabled` 标记——点"开启"会立刻清掉它，
  于是后端即使死了也显示成"已开启"。现在状态机以"真的在发信标"+"服务真实状态"为
  唯一来源，并新增"未运行（后端服务启动失败）"这一档。
- **`systemctl show` 多单元之间的空行**：真机核验发现它会在单元之间多输出一个空行，
  按行号 `read` 会整体错位（dnsmasq 在跑却报 `dhcp_active=no`，面板误报"DHCP 未运行"）。
- **`install.sh` 内容哈希漏掉 `contents/backend`**：只改后端时不会重装插件包，
  插件里「一键修复」用的副本会停在旧版。现在拆成"内容指纹"（含 backend，决定重装）
  与"界面指纹"（决定是否重启 plasmashell）。

### 设计纠正：「关闭热点」不再关闭「开机自启」

1.1.0 把两者捆在一起（`off` 会顺手关掉开机自启并 disable 单元），理由是评审里
"关了之后重启又自己冒出来"的抱怨。但这是两个开关：**关热点不该偷偷改用户的设置**
（用户反馈：为什么关闭热点后要关闭开机自启？请不要这样设计）。现在：

- **关闭热点** = 只停当前：停机制 + 恢复 Wi-Fi 频段 + 写一个**仅本次开机内有效**的
  "保持关闭"标记（防止本轮里服务被别的东西拉起来）。**不动开机自启**。
- **开机自启** = 只管"开机时要不要起"：只 enable/disable 单元，不启停当前热点。
- **切换模式** = 停两套 + 改写 MODE + **保留**自启设置（只把自启指向新模式的单元）。
- "保持关闭"标记只在本次开机内有效（`hs_marker_is_current` 比较标记时间与开机时间）：
  这样"关热点 + 开了自启"的用户重启后热点照常起来，而陈旧标记不会再压制自启。

### 测试

- 新增 `tests/test-supervisor.sh`：监督脚本 mock 端到端 **46 项**（不需要 root/网卡、
  不碰真实网络），覆盖上述崩溃回归、5G 回退 2.4G、`FALLBACK_2G=no`、非拒绝失败、
  DFS、陈旧标记忽略、保持关闭、坏凭据。
- `tests/test-config.sh`：+10 项（可选键默认值、标记是否属于本次开机）→ **79 项**。
- `tests/test-ctl.sh`：+20 项（崩溃重启循环必须报失败、多单元空行解析、
  关热点不动自启、切模式保留自启、陈旧标记）→ **128 项**。
- 合计 **253 项**，`tests/run-all.sh` 一条命令跑完（含 shellcheck 与 qmllint）。


### 1.1.1 之后的第二轮审计（4 个并行评审：安全 / shell 后端 / QML / 测试与文档）

**已修（每条都先在真机上核实过，不是照单全收）**

- **`kde-hotspot.sh` 的 `wiphy` 解析永远匹配不到**：真机 `iw dev <if> info` 输出是制表符缩进的
  `\twiphy 0`，而代码用 `/^wiphy/` → 永远取不到 → 默默回落到 `phy0`。多射频机器上 `ap0` 会建到
  错误的无线电（或直接失败、热点永远起不来）。改成 `$1=="wiphy"`，取不到就明确报错并写日志。
- **`sta_channel` 会串到下一个接口**：旧 awk 不设接口边界，STA 段没有 `channel` 行（=未连接）时会
  继续往下扫，把 `ap0` 的信道当成 STA 的 → "STA 离开信道 → 停热点重建"的逻辑永不触发，
  留下一个**没有上行的僵尸热点**（客户端连得上、上不了网）。改成按 `Interface` 行划段。
- **凭据长度按字符数而不是字节数校验，且两个调用方 locale 不同**：11 个汉字的 SSID 在面板
  （UTF-8，算 11 字符）被放行，systemd 服务（C locale，算 33 字节）拒掉 → 热点永远起不来、
  日志和面板都没有任何提示。`hs_cred_problem` 现在固定 `LC_ALL=C`（802.11 的长度上限本来就是字节），
  并且监督脚本在凭据不合法时会**明确写日志**。
- **`hs_conf_set` 号称原子其实不是**：`install` 会先 unlink 再创建（配置会短暂消失，并发 `status`
  会读到"配置不可读"，中途崩溃丢 SSID/密码）。改成"临时文件上设好属主/权限 + 同目录 `mv`"，
  并加了"400 次并发观察从未消失"的测试。`sync_dnsmasq` 同样改成先 chmod 再 `mv`。
- **切模式会留下 Wi-Fi 副作用**：`concurrent → normal` 不复位频段（Wi-Fi 被钉在 2.4GHz）、
  `normal → concurrent` 不把断开的 Wi-Fi 接回来。`do_mode` 现在会还原上一套机制的改动。
- **`restore_band` 先删备份再恢复、且无条件打印"已恢复"**：失败时用户被永久钉在 2.4GHz 且恢复数据已丢。
  现在确认成功才删备份，失败保留并如实记录。
- **`--pass-file` 的检查-使用竞态**：按路径 stat 之后再按路径 `cat`，调用者可在两步之间换成符号链接
  （例如指向 `/dev/zero` 让 root 无界读取）。现在**只打开一次**，之后所有属性检查（`/proc/self/fd`）
  与读取都针对同一个 fd，并限制最多读 4KiB；`/proc`、`/sys` 前缀直接拒绝。
- **不再接受命令行形式的密码**：`set-credentials SSID PASS` 会把密码暴露在 `pkexec` 的 argv
  （`/proc/<pid>/cmdline` 同机可读）。现在只接受 `--pass-file` 或 `-`（stdin）。
- **规则守卫的测试是假的**：iptables mock 让 `-C` 恒为真/恒为假，于是"每 ~15 秒重复插入 NAT/FORWARD"
  这类 bug（Docker 事故的修复点）在 CI 里看不出来。mock 改成**有状态**（记录/比对/删除真实规则），
  新增"同一套规则只插入一次"与"cleanup 真的拆干净"的断言。
- **`sync-helpers` / dnsmasq 渲染完全没测过**：`DNSMASQ_CONF` 提到顶层可注入，新增 8 条断言
  （接口/地址池/网关/DNS/bind-dynamic/644/内容没变不重启/变了才重启）。
- **QML 语法检查是一道空门**：CI 里 `qmllint` 根本不在 PATH（`command not found`）却打印 "QML 语法 OK"，
  而且判定 grep 文案（换个报错文案就永远通过）。现在：本地与 CI 都**用退出码**判定、CI 明确把
  `/usr/lib/qt6/bin` 加进 PATH、找不到 qmllint 直接失败，并各自带一个"故意写坏的文件必须失败"的自检。
- **QML：`status` 失败时不清空状态** → 后端被删/改名后面板永远显示最后一次成功的"运行中"。
  现在 stdout 为空即清空状态（`ready=false` → "后端不可用"）。
- **QML：动作源名重复** → executable 引擎对用过的源名会回放缓存、不重新执行，连点两次"开启"第二次可能无效。
  源名现在带自增序号。另加**动作看门狗**（60 秒）：pkexec 卡住时不再永久 `busy`。
- **QML：托盘文字与图标判定不一致**（图标画斜线、文字却显示频段）→ 统一按 `phase`。
- **`install.sh` 只重启"本来就在跑"的单元**（以前会把用户关着的热点拉起来）；
  `deploy.sh` 在取不到调用者信息时**不再猜组**（保持 600）；`KDE_HOTSPOT_CONF` 在 root 下需显式放行
  （deploy 自己放行），堵住"继承一个环境变量就让 root 改写任意文件"的口子。
- **status JSON 的所有字段统一走 `jstr`**，`clients` 只保留数字。

**经核实后不采纳 / 暂缓（含理由）**

- **"配置文件 640 给 netdev 可读 = 泄密"**：可读组与 polkit 授权组是同一批人，`status` 本来就把密码交给他们；
  改成为不给组读而让面板每次 `pkexec` 取密码反而更危险（每次 fork root）。
- **"root 脚本应固定 `PATH`"**：两个入口本身已经净化 PATH（pkexec 硬编 `/usr/sbin:/usr/bin:/sbin:/bin`，
  systemd 单元用默认 PATH），且固定 PATH 会破坏测试用的 mock 注入；判定为已覆盖，不改。
- **普通模式 PSK 出现在 `nmcli` argv**：真实存在（任一本地用户可读 `/proc/<pid>/cmdline`），
  但修复要改成 NM keyfile 导入 + 删除临时文件，属于行为变更、需要真机验证；已在 README「已知限制」写明，暂缓。
- **后端消息仍是中文 / config.qml 的 "General" 未被 xgettext 提取 / `cleanup`、`sync-helpers` 不输出 JSON**：
  都是接口或抽取范围的改动，已在 README「已知限制」记录，本轮不做。
- **`sta_channel` 之外的 `iw dev` 解析、hostapd 日志启发式**：mock 无法证伪真机 hostapd 的报错文案，
  已在测试注释里标注为"只能靠真机回归"。

**测试规模**：配置库 85 + 控制脚本 152 + 监督脚本 55 = **292 项**（本轮 +39），
另含 shellcheck、QML 语法（活门）、backend↔包内副本一致性。

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
- **`STA_IF` 自动探测更可靠**：改为优先取 NetworkManager 里**已连接的 Wi-Fi 设备**（其次才看 `iw dev` 的接口列表），
  并校验接口类型；旧实现取"第一个非 ap0 的接口"，可能选中插着但没用的无线口或非 Wi-Fi 设备。
- **`deploy.sh` 写配置不再有 644 窗口**：以前先 `install -m 644` 再 `chmod 640`，中间瞬间任何人都能读到密码；
  现在直接 `install -m 640`，并在非 root 场景保留原权限。
- **`CompactRepresentation` 的标签逻辑不可达**：`Plasmoid.formFactor` 在面板里是 `Horizontal`/`Vertical`，
  不是 `Planar`。现在按 `formFactor === Vertical || containmentType & CustomEmbeddedContainment ||
  containmentDisplayHints & ContainmentForcesSquarePlasmoids` 判断是否方形化，托盘里不再出现半截文字。

### 改进

- **5GHz 回退判定更准**：把 hostapd 的失败分成"明确拒绝该信道"（`Hardware does not support configured channel`、
  `Could not select hw_mode`、`Failed to set beacon parameters`、`Interface initialization failed`、`Channel is disabled`）
  与"其它退出"两类，前者才触发 2.4G 回退；另外识别 DFS/CAC（`DFS`/`radar`/`CAC`）并把等待期限从 15 秒放宽到 150 秒，
  避免把"正在等雷达检测"误判成失败。
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
- **"配置文件 640 给 netdev 组可读 = 明文密码泄露"（Qwen 2.1）**：不视为降级。可读该文件的组与 polkit 规则授权的组是同一批人，
  而 `status` 本来就把密码（和 SSID）交给这批人；反过来，若为了不给组读而让面板每 5 秒走一次 `pkexec` 取密码，
  等于每次轮询 fork 一个 root 进程并建立 polkit 会话——那才是真的更危险。可读范围已被收窄到 `root:<选定的那个组> 640`。
- **"更新时改为优先执行 root 拥有的 `deploy.sh` 副本"（DeepSeek 3.6-9）**：不采纳。更新流程的意义正是让**仓库里那份**
  新 `deploy.sh` 去装新后端；优先跑已安装的旧副本会让后端永远无法更新。至于"以 root 执行用户可写目录里的脚本"，
  这一步是用户自己执行 `bash install.sh` 并确认授权框的结果，与 `sudo make install` 同类；真要防的是"用户没同意就被执行"，
  而那已经由 polkit 的 `exec.path` 与"一键修复优先用 root 副本"覆盖。首次安装不可能避免，报告本身也承认这点。
- **"状态轮询改成自适应/事件驱动"（DeepSeek 3.6-11、GPT P1-7）**：暂不做。轮询已经从"每秒 fork root"降到
  "每 5 秒一次免特权只读查询"（约 -95%）；再拉长间隔会让托盘图标/悬浮提示在命令行开关后长时间显示旧状态，
  而"面板显示的状态必须可信"是本项目更看重的性质。要彻底解决得换成常驻 D-Bus 服务，属于上一条的架构改动。
- **`ProtectSystem=strict` + `ReadWritePaths`（DeepSeek 3.7）**：暂不做。当前主服务/普通模式单元是 `full`（`/usr`、`/etc` 已只读），
  改成 `strict` 需要准确列出运行时写入路径（`/run/kde-hotspot`、`/var/lib/kde-hotspot`），
  写错会让热点**在真机上直接起不来**，而这里没有网卡可验证——没有验证手段的加固不进主干。
- **给 `status` 的密码加 `STATUS_SHOW_PASS` 开关（DeepSeek 3.7）**：暂不做，保持"删掉 `do_status` 里的 `pass` 字段"
  的文档方案；多一个开关就多一条以后会被误配的路径。
- **面板内二维码/客户端列表/日志入口等体验建议（DeepSeek 3.7）**：属新功能，不在本次修复范围。
- **bash 后端复杂度（GPT P2-5）**：本次已经把配置读写抽成独立库（`kde-hotspot-config.sh`）并加上单测与端到端测试，
  这是往"可维护"走的第一步；继续拆分需要真实硬件回归，暂缓。

### 逐条对照（便于复查）

| 报告条目 | 处理 |
|---|---|
| DeepSeek 3.1 配置注入/RCE＋字符损坏 | 已修（新增配置库，纯数据解析）|
| DeepSeek 3.2 「开启中」取消按钮无效 | 已修（`awaitingHotspot` 时点击即发 `off`）|
| DeepSeek 3.3 模式/自启/保持关闭语义 | 已修（三者对称）|
| DeepSeek 3.4 status JSON 转义不全 | 已修（`\b\f` + 控制字符 → `\u00xx`）|
| DeepSeek 3.5 组授权与 polkit 不一致 | 已修（三处统一 + `conf.group`）|
| DeepSeek 3.6-1 待命态改凭据不生效 | 已修（`concurrent_running` 即重启）|
| DeepSeek 3.6-2 普通模式旧 profile 残留 | 已修（比对 SSID/PSK，不一致重建）|
| DeepSeek 3.6-3 /tmp 密码文件路径可预测 | 已修（`mktemp -d` + `umask 077` + 读取端校验属主/权限）|
| DeepSeek 3.6-4 清理规则依赖当前探测 | 已修（`rules.state` 记录实际使用值）|
| DeepSeek 3.6-5 硬编码 /24 与 AP_NET 矛盾 | 已修（由 AP_IP 派生 + 不一致告警）|
| DeepSeek 3.6-6 普通模式客户端数恒为 0 | 已修（hostapd 快照 / ARP）|
| DeepSeek 3.6-7 DHCP 失败静默 | 已修（`do_on` 检查 DHCP 单元 + `dhcp_active` + 面板警告）|
| DeepSeek 3.6-8 配置文件 644 窗口 | 已修（`install -m 640`）|
| DeepSeek 3.6-9 install.sh 以 root 跑仓库脚本 | 不采纳（见上）|
| DeepSeek 3.6-10 面板标签显示条件 | 已修（按 `formFactor===Vertical` + 托盘方形提示判定）|
| DeepSeek 3.6-11 轮询成本 | 已改善（1s→5s 且免特权），自适应暂不做（见上）|
| DeepSeek 3.6-12 高级配置需手动重启 | 已写入 README/config.example |
| DeepSeek 3.6-13 无 CI/测试/tag/CHANGELOG | 已补（CI、两套测试、本文件、v1.1.0 tag）|
| GPT P0-1~P0-4 | 全部已修（配置不 source、pass-file、临时文件、capabilities）|
| GPT P1-1 AP_IP/AP_NET/DHCP 不一致 | 已修 |
| GPT P1-2 租约数≠在线客户端 | 已修 |
| GPT P1-3 普通模式只存连接名 | 已修（存 UUID）|
| GPT P1-4 关闭时可能恢复错误 Wi-Fi | 已修（用户已连别的 Wi-Fi 就不抢）|
| GPT P1-5 5G 回退依赖日志启发式 | 已改善（分类判定 + DFS/CAC 期限）|
| GPT P1-6 监管域默认 CN | 已修（不再硬编）|
| GPT P1-7 3 秒轮询 + 两次 miss | 保留（跟随信道所必需，见上）|
| GPT P2-1 两份后端源码 | 保留 + `--check` 与 CI 拦住不一致 |
| GPT P2-2 QML 通过字符串调 pkexec | 保留（D-Bus 重构超出范围）|
| GPT P2-3 默认重启 plasmashell | 早已按内容哈希判断 |
| GPT P2-4 缺自动化测试 | 已补 |
| GPT P2-5 bash 复杂度 | 已抽出配置库并加测试，继续拆分暂缓 |
| Qwen 2.1 配置文件权限 | 说明（见上）|
| Qwen 2.2 polkit 范围 | 已收窄到单脚本 + 组统一 |
| Qwen 3.1 53 端口冲突 | 不成立（`bind-dynamic` 只绑 ap0）|
| Qwen 3.2 网卡自动探测 | 已修（优先 NM 已连接设备）|
| Qwen 3.3 NM 连接被永久修改 | 已修（频段/连接 UUID 备份并恢复）|
| Qwen 3.4 双份后端 | 同 GPT P2-1 |
| Qwen 4.1 硬编码 dnsmasq.leases | 已修 |
| Qwen 4.2 配置修改方式不一致 | 已修（唯一写入口 `hs_conf_set`）|
| Qwen 4.3 缺 IPv6 | 不做（超出范围）|
| Qwen 4.4 规则残留 | 已修（按记录拆）|

## 1.0.0

首个发布版本：并发模式（hostapd + 虚拟 `ap0`，跟随 Wi-Fi 信道，5GHz 被固件拒绝时自动回退 2.4GHz）
与普通模式（NetworkManager 原生热点）；Plasma 6 托盘插件 + 桌面入口；polkit 免密授权；
依赖自检与一键修复命令；中英双语界面。
