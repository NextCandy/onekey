# onekey 项目约定

Surge / Shadowrocket 一键部署脚本（Hysteria2 + Snell v5）。主体是单文件 `install.sh`（bash，`set -euo pipefail`）。

**进度、测试结论和待办见 [docs/PROGRESS.md](docs/PROGRESS.md)，开始工作前先读。**

## 沟通

- 始终用中文回复
- 公开仓库：代码、文档、提交信息中**不得出现**密码、PSK、私钥、真实 IP、真实域名；服务器用别名（如 `us-hy`）
- 不要让用户粘贴私钥或云厂商 Token；SSH 使用本地 `~/.ssh/config` 中的别名

## 修改脚本

- 保持交互式循环菜单：每个操作在子 shell 中运行，出错只结束当前操作并回到菜单；同时保留命令行参数入口
- `set -euo pipefail` 下注意：可能失败的管道（如 `ping` 不通）要吞掉退出码；函数末尾不要以 `[[ ... ]] && ...` 结尾
- 新增菜单项时同步修改：菜单文字、`case` 分支、`main` 参数、README 菜单与参数说明
- 文件必须是 LF 换行（`.gitattributes` 已约束），提交前 `bash -n install.sh`
- 提交前检查敏感信息：`grep -rnE '<密码或IP片段>' . --exclude-dir=.git`
- 修改后同步更新 `SCRIPT_VERSION`、README、`docs/PROGRESS.md`

## 测试

- 能在本地测的先本地测：把 `install.sh` 去掉最后一行 `main "$@"` 后 `source`，用桩函数测单个函数
- 涉及 sysctl / tc 的改动可在 WSL 中测试"应用 → 回滚"，并核对文件、运行时参数、队列是否完全恢复
- 在服务器上测试时优先只读；需要改动服务器配置、SSH、防火墙时先征得用户同意
- 服务器上的临时测试文件用唯一文件名（如 `/root/oktest-$RANDOM.sh`），测完清理
- 如实报告：哪些实测过、哪些只做了语法/副本校验、哪些未测

## 网络调优原则

先测量、有证据才改、可回滚。明确角色（落地 / 中转）和关键方向（通常是 VPS 出口 → 用户下载）；逐个 peer 测试，看重传、队列丢包、UDP 错误的**增量**；MTU / TBF / 大缓冲都只是候选值；网卡队列无丢包但重传高 → 路径问题，不靠本机调参解决；UDP/QUIC 协议不受 TCP 缓冲影响。

## Git

- 提交作者使用 GitHub 隐藏邮箱：`20787873+NextCandy@users.noreply.github.com`（仓库级配置）
- 提交信息结尾：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
