# 无畏契约退出后 ACE 隔离守护

[English](README.md)

检测 `VALORANT.exe` 和 `VALORANT-Win64-Shipping.exe`。全部游戏进程退出并稳定
30秒后，备份首次发现的启动配置，禁用识别到的ACE服务／驱动后续启动入口，
再通过Windows右下角通知报告实际结果。游戏重新启动会取消等待中的清理。

它不会结束游戏、强制卸载内核驱动或重启电脑。禁用启动不等于卸载已经运行的
驱动，通知会明确区分仍在运行、状态未知及部分失败。该工具用于隔离验证，
不能证明某次蓝屏或重启一定由ACE导致。

## 安装

需要64位Windows、Windows PowerShell 5.1、.NET Framework 4.8及管理员权限。
将仓库放在固定的本地NTFS目录，以管理员身份打开**64位Windows PowerShell**，
进入仓库目录后运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Manage-Guard.ps1 -Action Install
```

安装会运行测试、注册登录启动任务 `Valorant.AceExitGuard`、启动守护并验证状态。
如果游戏已经关闭，会立即执行一次初始清理。后续每次退出游戏无需再次点UAC。
若守护已成功启动但初次清理失败，会分别记录结果并返回退出码2，守护仍保持安装。
守护在用户登录后运行，不在登录前运行；安装后请保留原目录，不要移动。

游戏启动器可能在下次启动时重新安装或启用ACE。守护不会替你启用ACE，也不
保证依赖ACE的游戏在相关入口被禁用时仍能正常启动。

## 查看、更新与卸载

```powershell
.\Manage-Guard.ps1 -Action Status
# 以下两项需要管理员权限：
.\Manage-Guard.ps1 -Action Update
.\Manage-Guard.ps1 -Action Uninstall
```

卸载只停止并移除守护任务，保留记录，不自动恢复ACE启动配置。首次原值位于
`.runtime\data\original_start_values.json`。托盘菜单可打开最近一次隔离记录；
“退出守护”只停止本次运行，下次登录仍会启动。

通知受Windows通知设置影响。日志里的 `NotificationRequested` 表示已请求，
`NotificationShown` 才表示收到系统显示事件。失败会单独提示，不冒充成功。

## 测试及记录

```powershell
# 不改服务、不启动游戏：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Guard.ps1
# 管理员权限，附加无害进程的真实WMI启动／退出事件测试：
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Guard.ps1 -RunEventProbe
# 管理员权限，首次清理完成后核验：
.\Verify-Guard.ps1
```

运行记录位于 `.runtime\data`，测试输出位于 `data`；两者都被Git忽略，避免
上传账户、路径及本机状态。完整工作方式、权限保护、限制和文件说明见
[英文README](README.md)。
