# pve-trafficd

Proxmox VE 9 的虚拟机流量统计插件：按网卡统计自上次重置（last-reset）以来的流量，
达到配额（quota）后自动限速——把虚拟机配置里该网卡的 `rate` 改成限速值并立即生效，
重置后恢复原来的速率。计费周期由外部系统通过 API 调用重置来实现，插件本身不管周期；
图表沿用 PVE 自带的。

## 功能

- **按网卡统计**（`net0`、`net1`…，每块网卡单独配置）：入流量（虚拟机收到）、出流量（虚拟机发出），
  计入配额的方向可选：`both`（入 + 出，默认）、`in`、`out`、`max`（取两者中较大的）。
- **last-reset 与 current-quota**：每块网卡一个计数周期，起点是 last-reset（创建配置或最近一次重置的时间）。
  重置时可以同时设置新周期的配额，并返回刚结束的周期的流量。不设配额时只统计、不限速。
- **自动限速**：周期内计入的流量 ≥ 配额时，把虚拟机配置中该网卡的 `rate` 设为限速值（MB/s，与 PVE
  网卡限速同单位，可按网卡设置，否则用集群默认值，内置默认 1 MB/s），运行中的虚拟机立即生效
  （与 PVE 在线修改 rate 相同）。原速率被记下，重置、提高配额、删除配置后恢复。
  - 网卡原本就比限速值慢的，保持原速率；
  - 限速期间 rate 被改动（手工修改、重建虚拟机）会被重新限速，改动后的值成为新的“原速率”；
  - 恢复时若 rate 已不是插件设的值，保留当前值不动。
- **重建虚拟机不丢数据**：配置和计数按 VMID + 网卡保存在 `/etc/pve/trafficd/`，与虚拟机配置无关，
  虚拟机删除后保留。以同一 VMID 重新创建（IDC 重装系统）后继续累计；处于限速状态的，新虚拟机
  一出现就重新限速（虚拟机启动时立即检查）。
- **关机时数据完整**：tap 设备被删除时，内核的通知（RTM_DELLINK）带着它最终的计数，虚拟机关机、
  崩溃、被 kill、迁出、网卡热拔都能统计到最后一个字节。宿主关机/重启时服务排在 `pve-guests`、
  `pve-ha-lrm` 和 `qemu.slice` 之后停止：等所有虚拟机停完、最终计数到手再写出。
  集群文件系统不可写（无 quorum，例如整个集群一起关机）时数据存在本地，开机后补写。
- **迁移**：计数是集群范围的——每个节点只记录在本节点上产生的流量，写在自己的计数文件里，
  总量是各节点之和。在线迁移、离线迁移、HA 迁移后继续累计，限速随虚拟机配置一起走。
- **守护进程重启不重复、不丢失**：`/run` 中按设备实例（ifindex）保存基线，服务重启、升级期间的流量照常计入。
- **Web 配置页**：
  - 数据中心 → Traffic：集群默认值（限速值、计数方向），集群内全部已配置网卡的用量/配额/状态，
    可新增、编辑、重置、删除。
  - 虚拟机 → Traffic：该虚拟机各网卡的用量、配额、限速状态，可配置、重置、删除。
- **API 与命令行**，见下文。
- **可安装、可卸载**：标准 deb 包。卸载时恢复本节点上被限速网卡的原速率，并恢复被替换的 PVE 文件。
- **与 [pve-routedip](../pve-routedip) 兼容**：两者替换的 PVE 文件不同，Web 页面各自挂载、互不影响，
  安装/卸载顺序任意；routedip 的 tap-only 网卡同样统计和限速。

只支持 QEMU 虚拟机。

## 安装

集群所有节点都需要安装（配置和计数是集群共享的，统计和限速由虚拟机所在节点完成）：

```sh
make deb                      # 需要 debhelper、libpve-common-perl
apt install ./pve-trafficd_1.0.0_all.deb
```

pvedaemon、pveproxy 由 PVE 的 `pve-api-updates` 触发器自动重载，刷新浏览器即可看到新页面。

卸载：`apt remove pve-trafficd`。`/etc/pve/trafficd/` 中的配置和计数是集群共享的，卸载与 purge 都不会删除它；
purge 删除本节点的 `/var/lib/pve-trafficd`。

## 使用

命令行（`pve-traffic`）：

```sh
pve-traffic set 100 net0 --quota 1T --rate 1      # 创建/修改，创建即开始计数
pve-traffic set 100 net0 --direction max --delete rate
pve-traffic show 100                              # 该虚拟机各网卡
pve-traffic list                                  # 集群内全部已配置网卡
pve-traffic reset 100 net0 --quota 2T             # 新周期，返回上个周期的流量
pve-traffic delete 100 net0                       # 不再统计（限速中的先恢复原速率）
pve-traffic options set --rate 0.5 --direction both
pve-traffic status                                # 本节点守护进程跟踪的 tap 设备
```

配额：字节数，或带单位：`K M G T P`（及 `Ki`/`KiB`…）是 1024 进制，与 PVE 磁盘大小写法相同；
`KB MB GB TB PB` 是 1000 进制。限速值单位 MB/s，最小 0.001。

### API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/cluster/trafficd/options` | 集群默认值 `rate`、`direction` |
| PUT | `/cluster/trafficd/options` | 修改默认值（`delete` 恢复内置默认） |
| GET | `/cluster/trafficd/vms` | 全部已配置网卡（含已删除虚拟机的，`orphan`） |
| GET | `/cluster/trafficd/vms/{vmid}` | 某虚拟机的全部网卡（已配置和未配置的） |
| GET | `/cluster/trafficd/vms/{vmid}/{net}` | 单块网卡的配置与计数 |
| PUT | `/cluster/trafficd/vms/{vmid}/{net}` | 创建/修改：`quota`、`rate`、`direction`、`delete` |
| DELETE | `/cluster/trafficd/vms/{vmid}/{net}` | 删除配置；正在限速的，先由虚拟机所在节点恢复原速率再删除（期间 `removing`） |
| POST | `/cluster/trafficd/vms/{vmid}/{net}/reset` | 重置（可带新 `quota`），返回上个周期的 `netin`/`netout`/`used` |

返回的计数字段：`netin`、`netout`、`used`（计入配额的字节数）、`quota`、`last-reset`（UNIX 时间）、
`exceeded`（已达配额）、`limited`（限速已生效）、`orig-rate`（限速前的速率）、`effective-rate`、`effective-direction`。
`/cluster/trafficd/vms/{vmid}…` 的请求自动转发到虚拟机所在节点，数据是最新的（≤ 5 秒）；
`/cluster/trafficd/vms` 中其它节点上虚拟机的数据最多晚 20 秒。修改后限速状态在 1–2 秒内跟上。

权限：读需要虚拟机上的 `VM.Audit`；写（含重置）需要虚拟机上的 `VM.Config.Network` 以及 `/` 上的
`Sys.Modify`（配额属于宿主的计费控制，虚拟机使用者不能自己重置）；集群默认值需要 `/` 上的 `Sys.Audit`/`Sys.Modify`。

外部计费系统建议使用 API token（内置角色中只有 Administrator 含 `Sys.Modify`，可建一个专用角色），例如：

```sh
pveum role add TrafficBilling --privs "VM.Audit VM.Config.Network Sys.Audit Sys.Modify"
pveum user add billing@pve
pveum acl modify / --users billing@pve --roles TrafficBilling
pveum user token add billing@pve traffic --privsep 0

curl -sk -H 'Authorization: PVEAPIToken=billing@pve!traffic=<secret>' \
    -X POST https://pve1:8006/api2/json/cluster/trafficd/vms/100/net0/reset -d quota=1T
```

## 文件

```
/etc/pve/trafficd/options.cfg        集群默认值（rate、direction）
/etc/pve/trafficd/<vmid>.cfg         每块网卡一行，例如：
                                     net0: last-reset=1791763200.000123,quota=1099511627776,rate=1
                                     限速中另有 limited=1、orig-rate、applied（由守护进程写入）
/etc/pve/trafficd/usage/<node>.json  该节点产生的流量（只由该节点写）
/var/lib/pve-trafficd/usage.json     本节点计数的本地副本（无 quorum 时也能保存）
/run/pve-trafficd/state.json         守护进程状态：tap 设备基线和最新计数（每 5 秒）
```

## 实现说明

- `pve-trafficd` 守护进程（每个节点）：
  - 每 5 秒通过 rtnetlink 读取所有 tap 设备的 64 位计数，同时订阅链路通知，tap 设备被删除时从通知中取得最终计数；
    `tapXiY` 的接收（rx）是虚拟机发出的流量，发送（tx）是虚拟机收到的流量；
  - 基线按 ifindex 记录，新建的设备从 0 开始计；首次安装时已存在的设备只统计安装之后的流量；
  - 计数写入 `/run`（每次读取后），每 20 秒（虚拟机停止后 1 秒内）写入本节点的计数文件和本地副本；
  - 每秒检查配置变化和限速：只处理配置在本节点的虚拟机，在虚拟机配置锁和集群锁下修改 `netX` 的 `rate`
    （含 pending 中的同一网卡），运行中的虚拟机用 PVE 的 `tap_rate_limit` 立即生效；
    虚拟机被锁（迁移、快照等）时稍后重试，备份锁除外。
- 重置只是开始一个新周期（last-reset 带微秒，即周期标识），旧周期的计数被忽略并由各节点清理。
- 安装时用 `dpkg-divert` 替换 `PVE/API2/Cluster.pm`（pve-manager），替换后的模块先原样加载原文件再注册
  `/cluster/trafficd`；pve-routedip 替换的是 `PVE/API2.pm` 和 `PVE/Network.pm`，互不冲突。Web 界面通过在
  `index.html.tpl` 中插入 script 标签加载，pve-manager 升级后由 dpkg 触发器重新插入。

## 限制

- 只支持 QEMU 虚拟机（LXC 容器的 veth 不统计）。
- 计数是二层帧长度（不含 FCS），与 PVE 图表中的网卡流量一致。
- 节点断电（非正常关机）会丢失该节点最近未写出的计数（最多约 20 秒）；守护进程未运行期间删除的 tap 设备，
  其最后一次读取之后的流量无法统计。
- 达到配额到限速生效最多约 5 秒（一次计数间隔）；新虚拟机启动后几秒内（启动完成、拿到配置锁之前）尚未限速。
- 限速通过 PVE 的网卡 rate 实现（tc，进出两个方向同时限速）。
- 跨集群的远程迁移（`qm remote-migrate`）不会带走计数和配置。
- 所有节点都要安装：未安装的节点上运行的虚拟机既不统计也不限速。

## 开发

```sh
make check    # 单元测试，需要 libpve-common-perl
make deb
PROJECT=pve-trafficd ~/pve-lab/deploy.sh   # 在 lab 的 chroot 中构建并安装到 pve1、pve2
```
