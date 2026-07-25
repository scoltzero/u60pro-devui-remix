# 双卡管理与持久流量

Remix 在“更多功能”页提供两个仅限双卡 U60Pro 显示的内置页面：

| 页面 | 路径 | 作用 |
|------|------|------|
| 双卡管理 | `ui/functions/sim-switch.html` | 驻网模式、智能切换、当前数据卡和卡槽状态 |
| 双卡流量 | `ui/functions/sim-traffic.html` | 按 ICCID 持久统计、套餐额度和每月重置日 |

页面入口要求厂商接口返回 `support_dual_sim=1`。双卡流量页还要求配套
`zwrt-datad` 在 `/state` 中提供 `sim_traffic.available=true`，单卡设备和旧后端不会显示入口。

## 双卡控制

DevUI 只允许以下固定动作：

| act | 含义 |
|-----|------|
| `act:simmanage:single` | 切换为单卡模式 |
| `act:simmanage:dual` | 切换为双卡双待 |
| `act:simslot:1` / `act:simslot:2` | 切换自插卡 / 内置卡 |
| `act:simsmart:0` / `act:simsmart:1` | 关闭 / 开启智能切换 |
| `act:simmoderefresh` | 刷新双卡状态 |

驻网模式和数据卡切换均使用 4 秒二次确认，并在后台调用 U60Pro 固定 `ubus` 接口。
操作期间共用一个状态锁，最多等待 60 秒，以真实卡槽和 provision 状态回读判断成功，
不会执行页面提供的任意 Shell 命令。

## 流量统计

配套 datad 从 `zwrt_data.get_wwandst` 读取当前蜂窝会话计数，并按 ICCID 哈希分开保存：

```text
/data/plugins/zwrt-datad/traffic-state.json
/data/plugins/zwrt-datad/traffic-config.json
/data/plugins/zwrt-datad/timezone.json
```

- 进程和设备重启后继续累计，计数器回退时只重建基线，不把异常差值计入用量。
- 普通采样只更新内存，最多每 5 分钟写盘；切卡和正常退出时强制保存。
- 今日和套餐周期使用 DevUI 固定偏移时区，不依赖系统 `TZ`。
- 套餐以整 GiB 设置，可为每张已识别 ICCID 独立启用，并设置每月 `1-31` 日重置。
- 页面只展示当前或最近使用的每个卡槽记录；历史记录仍保留在 datad 状态文件中。

## 安全边界

- `sim-switch.html` 不再依赖或打包独立 `simctl.sh`。
- 切卡、单卡/双卡切换共用 DevUI 原有的异步确认状态机。
- 流量和时区设置只通过监听 `127.0.0.1:9460` 的 datad 固定 API 提交。
- ICCID 不直接显示或写入 UI 日志，页面只显示末四位。
