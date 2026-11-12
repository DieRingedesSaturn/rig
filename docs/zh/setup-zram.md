# setup-zram.sh

基于 `systemd-zram-generator` 的压缩 zram swap，附带可选的磁盘 swapfile。默认不触碰已有磁盘 swap，让它在 zram 用满时继续兜底。

## 行为

| 项目 | 默认值 | 说明 |
|------|--------|------|
| zram | 启用 | Debian/Ubuntu 安装 `systemd-zram-generator`，Fedora/RHEL/Arch 安装 `zram-generator` |
| zram 大小 | `auto` | 内存的 1/3，上限 1024 MiB；也可直接填 MiB 数值 |
| 压缩算法 | `zstd` | `zstd`、`lz4`、`lzo`、`lzo-rle`、`deflate` 或 `842` |
| swap 优先级 | 100 | 优先使用 zram，再落到磁盘 swap |
| sysctl 调优 | 启用 | `vm.swappiness=100`、`vm.page-cluster=0` |
| swapfile | 关闭 | 可选 `/swapfile`（默认 1024 MiB），并写入带标记的 `/etc/fstab` 条目 |

生成器与发行版无关：读取 `/etc/systemd/zram-generator.conf`，创建 `zram0`，并生成 `systemd-zram-setup@zram0.service` 与 `dev-zram0.swap`。Rig 会启动这两个 unit，并实际检查 `/dev/zram0` 是否出现在 `/proc/swaps` 中。

修改大小或压缩算法会重建 `zram0`。重建前先停止 swap unit，把已换出的页换回内存，再 reset 设备。

## 写入的文件

| 文件 | 用途 |
|------|------|
| `/etc/systemd/zram-generator.conf` | 托管的 zram0 定义（首行含 rig 标记） |
| `/etc/sysctl.d/99-rig-zram.conf` | `vm.swappiness` / `vm.page-cluster` 调优 |
| `/swapfile` | 仅在启用 swapfile 时创建 |
| `/etc/fstab` | 仅在启用 swapfile 时写入带标记的条目 |

替换既有文件前会在 `~/.local/share/rig/backups/system` 生成时间戳备份。非 rig 托管的 `zram-generator.conf` 或 sysctl 文件必须经交互明确同意才可覆盖；选择保留（包括非交互和 `--yes` 模式）会在修改系统前终止该组件。已有的非托管 `/swapfile` fstab 条目不会被修改，只有紧跟 Rig 标记的 swap 条目才会被认领。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `RIG_ZRAM_ENABLE` | `yes` | `yes` / `no` |
| `RIG_ZRAM_SIZE` | `auto` | `auto` 或 MiB（1-1048576） |
| `RIG_ZRAM_COMPRESSION` | `zstd` | 压缩算法 |
| `RIG_SWAPFILE_ENABLE` | `no` | 是否创建并托管 swapfile |
| `RIG_SWAPFILE_SIZE` | `1024` | swapfile 大小（MiB） |

## 卸载

`uninstall.sh --components zram` 会停止 `dev-zram0.swap` 与 setup unit、reset `zram0`、删除两个托管配置文件、还原 `/etc/fstab` 并删除托管 swapfile。`zram-generator` 软件包会保留。
