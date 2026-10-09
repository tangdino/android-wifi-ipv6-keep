# android-wifi-ipv6-keep（中文说明）

适用于 **已 Root 安卓手机** 的 IPv6 **默认路由保底**脚本。

解决这样一个问题：**Wi-Fi 一直连着、IPv6 地址也还在，但过一段时间 IPv6 就用不了了**
——常见原因是路由器通告（RA）生成的默认路由过期或没有被及时刷新。

> 它**不会重连 Wi-Fi**，**不碰 IPv4**，只负责维护一条低优先级的备用 IPv6 默认路由。

---

## 一、它能解决什么

- Wi-Fi 正常连接、IPv6 地址存在，但一段时间后 IPv6 失效（RA 默认路由丢失/未刷新）。
- 路由器下发的 RA 有效期很短，或者不再持续刷新。

## 二、它解决不了什么（重要）

- **Wi-Fi 本身断开** —— 本脚本从不重连 Wi-Fi。
- **路由器上游宽带断网** —— 网关可达 ≠ 公网可用，脚本管不到上游。
- **DNS 故障**。
- **IPv4 问题** —— 本脚本只管 IPv6。

## 三、前提条件

- 已 Root（Magisk / KernelSU / APatch）
- 无线接口名为 `wlan0`（如果你的不是，需修改脚本里的 `IFACE=`）
- 网络本身确实提供 IPv6
  （如果 Wi-Fi 只有 IPv4，脚本会保持待命、不添加任何路由，这是设计如此）

---

## 四、安装

### 方法一：一键安装（推荐）

```sh
su -c 'sh /sdcard/Download/deploy-wifi-keep.sh'
```

部署脚本是自包含的，会自动完成：
备份旧脚本 → 写入 `wifi-keep.sh` → 语法自检（失败自动回滚）→ 结束旧进程 → 启动新进程。

### 方法二：手动安装

```sh
su
cp wifi-keep.sh /data/adb/service.d/wifi-keep.sh
chmod 755 /data/adb/service.d/wifi-keep.sh
chown 0:0 /data/adb/service.d/wifi-keep.sh
sh -n /data/adb/service.d/wifi-keep.sh && echo SYNTAX_OK
nohup /system/bin/sh /data/adb/service.d/wifi-keep.sh >> /data/adb/wifi-keep/launcher.log 2>&1 </dev/null &
```

开机后由 `service.d` 自动启动，无需手动干预。

---

## 五、验证是否生效

```sh
ip -6 route show table wlan0
```

应该能看到**两条**默认路由：

```
default via fe80:... dev wlan0 proto ra  metric 1024 ...   ← 正常路由（来自 RA）
default via fe80:... dev wlan0 proto 99  metric 4096 ...   ← 备用路由（本脚本添加）
```

`proto 99` + `metric 4096` 是本脚本的"签名"。
它**只会删除带有这个签名的路由，绝不碰正常的 RA 路由**。

---

## 六、工作原理

1. 从现有的 RA 默认路由中读取网关（同时继承其 MTU）。
2. 验证网关是否存活（`ping6` + 邻居表 MAC 核对）。
3. 添加备用默认路由：`proto 99 metric 4096`，**不设有效期**（避免随 RA 一起过期）。
4. 每 **300 秒**复查网关健康；失败后改为 **60 秒**重试，连续失败 3 次告警
   —— 但**绝不因为 ping 失败就删除备用路由**。
5. 当安卓默认网络切换到**移动数据**时，自动暂停并清除备用路由；
   切回 Wi-Fi 后自动恢复并重新验证。
6. 网关变化时用 `ip route replace` **原子切换**，先验证新网关再替换，无中断空窗。

### 关于"连着 Wi-Fi 但没有 IPv6"

脚本会先每 **30 秒**检查两分钟，确认没有 IPv6 后降为每 **300 秒**检查一次，
期间 Wi-Fi 一有地址/路由事件就立刻唤醒。整个过程不探测、不改设置、不添加路由。

---

## 七、安全说明

- 只删除匹配 `proto 99` + `metric 4096` 的路由（即它自己添加的）。
- 从不重连 Wi-Fi，也不改变你的网络选择。
- 会设置 `accept_ra=2`、`accept_ra_min_lft=1`，并关闭 Wi-Fi 省电
  （`KEEP_POWER_SAVE_OFF=1`）；**这些在脚本退出时不会自动还原**。
- 不申请 wakelock；空闲轮询开销极低（约占空比 0.12%）。

---

## 八、日志

```sh
tail -f /data/adb/wifi-keep/wifi-keep.log
```

常见日志含义：

| 日志 | 含义 |
|---|---|
| `fallback=installed gateway_health=verified` | 备用路由已安装，网关已验证 |
| `guard=paused default_network=cellular` | 已切换到移动数据，暂停并清除备用路由 |
| `guard=active default_network=wifi` | 已切回 Wi-Fi，自动恢复 |
| `no usable IPv6 on Wi-Fi` | 当前 Wi-Fi 无可用 IPv6，进入降频等待 |
| `WARNING: gateway health suspect` | 网关连续探测失败（仍保留备用路由，不删除） |

---

## 九、许可证

MIT
