# Windows Server Agent 实现计划

## 1. 目标与背景 (Goal & Context)

* **需求背景**：现有 Agent 已支持 Linux、macOS 和 Docker，但 Windows Server 节点没有原生 exe、服务注册和一键安装路径，无法接入 OpenFlare 的主动拉取配置模型。
* **开发范围 (Scope)**：新增 Windows amd64/arm64 Agent 发布资产；让 Agent 以 Windows Service 或前台进程运行；新增 PowerShell 安装/卸载脚本、SHA-256 校验和控制台部署命令；补齐 Windows 主机观测和中文部署设计文档。
* **不在范围**：自动安装 OpenResty、修改 Server Agent 协议、远程命令执行和 Windows 专属运维面板。

## 2. 设计与决策

* 复用现有 Agent HTTP/WebSocket、配置版本、回滚和自更新协议，避免 Windows 节点形成第二套行为。
* 使用 Windows Service Control Manager 管理 Agent 生命周期；服务停止事件取消 Agent 根 context，保证心跳、WS、GeoIP 更新等 goroutine 都能结束。
* 安装器使用 PowerShell 原生下载、哈希验证、配置生成和 `New-Service`，不要求 Docker 或额外运行时。OpenResty 作为显式前置依赖检查。
* Windows 观测使用 `golang.org/x/sys/windows` 的系统 API；Linux `/proc` 实现通过 build tag 保持不变。

## 3. 修改文件清单

### Agent

* [MODIFY] `cmd/agent/main.go`：抽取可复用运行函数并接入 Windows Service 生命周期。
* [NEW] `cmd/agent/service_windows.go`、`cmd/agent/service_unix.go`：平台服务入口。
* [MODIFY] `internal/apps/agent/runtimeuser/runtimeuser.go`：Windows 跳过 Unix UID/GID 权限动作。
* [MODIFY] `internal/apps/agent/nginx/manager.go`：Windows 移除不适用的 `user` 指令。
* [MODIFY] `internal/apps/edge/observability/linux.go`、`linux_test.go`：限定非 Windows 构建。
* [NEW] `internal/apps/edge/observability/windows.go`、`windows_test.go`：Windows 系统观测。

### 安装与发布

* [NEW] `scripts/install-agent.ps1`：Windows 一键下载、校验、配置和服务注册。
* [NEW] `scripts/uninstall-agent.ps1`：停止服务并清理安装目录。
* [MODIFY] `.github/workflows/build-release.yml`：构建 Windows Agent 并发布校验文件。
* [MODIFY] `go.mod`：声明 Windows Service 与系统 API 依赖。

### 控制台与文档

* [MODIFY] `frontend/app/(main)/nodes/components/node-utils.ts`、`install-command.tsx`：生成 Windows 安装命令。
* [NEW] `docs/design/windows-agent-design.md`：Windows 运行与安全边界设计。
* [MODIFY] `docs/design/architecture.md`、`docs/config.ts`、`docs/deployment/agent.md`、`docs/reference/configuration.md`、`docs/plan/index.md`、`docs/changelog/index.md`：同步中文设计、部署和变更说明。

## 4. 验证计划

* Go 单元测试：`go test ./internal/apps/agent/... ./internal/apps/edge/observability/...`。
* Windows 构建：`GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build ./cmd/agent`，并检查 arm64 构建。
* 脚本语法/静态检查：使用 PowerShell Parser 检查 `.ps1`；Linux shell 安装脚本保持可执行。
* 仓库门禁：执行 `make format` 和 `make code-check`。

## 5. 当前验证记录

* 已通过：Windows 观测包 `go test` / `go vet`、Go 格式检查、`git diff --check`、Release Workflow YAML 解析、Linux 安装脚本 `bash -n` 以及本次前端文件的 Biome 检查。
* 追加：WebSocket 收发链路已增加消息字节数、空消息和非法 JSON 的可见诊断，并保留配置应用错误与连接关闭的独立记录。
* 未完成：本机没有 PowerShell，无法运行 `.ps1` Parser；`make format` 需要联网安装缺失的 `goimports`，`make code-check` 需要本机未安装的 `rg` 与 `golangci-lint`；Windows Agent 交叉构建因 Go 模块缓存不完整且网络下载超时未能完成。
