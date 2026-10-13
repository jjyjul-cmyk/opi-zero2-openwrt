#!/usr/bin/env bash
#
# 一条命令走完：建 GitHub 仓库 → 推代码 → 触发 Actions → 等编译 → 下载固件
#
# 用法：
#   GITHUB_TOKEN=ghp_xxxxxxxx bash tools/publish.sh                      # 公开仓库
#   GITHUB_TOKEN=ghp_xxxxxxxx bash tools/publish.sh my-repo --private    # 私有仓库
#
# Token 需要什么权限：
#   classic token      → 勾 repo + workflow
#   fine-grained token → Administration: write（建仓库） + Contents: write + Actions: write + Workflows: write
#
# 注意：token 只用于拼 URL 直接 push，不会写进 .git/config，也不会落到磁盘上。
#
set -euo pipefail

TOKEN="${GITHUB_TOKEN:-}"
REPO_NAME="${1:-opi-zero2-openwrt}"
VISIBILITY="public"
[ "${2:-}" = "--private" ] && VISIBILITY="private"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
API="https://api.github.com"

[ -n "$TOKEN" ] || { echo "!! 请先设置 GITHUB_TOKEN"; exit 1; }
command -v git >/dev/null || { echo "!! 需要 git"; exit 1; }

api() {
	curl -fsSL -H "Authorization: Bearer $TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

echo ">>> 1/6 确认账号"
LOGIN="$(api "$API/user" | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$LOGIN" ] || { echo "!! token 无效或没有读用户信息的权限"; exit 1; }
echo "  登录身份: $LOGIN"

echo ">>> 2/6 创建仓库 $LOGIN/$REPO_NAME ($VISIBILITY)"
if api "$API/repos/$LOGIN/$REPO_NAME" >/dev/null 2>&1; then
	echo "  仓库已存在，复用"
else
	curl -fsSL -X POST "$API/user/repos" \
		-H "Authorization: Bearer $TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-d "{\"name\":\"$REPO_NAME\",\"private\":$([ "$VISIBILITY" = private ] && echo true || echo false),\"description\":\"OpenWrt for Orange Pi Zero 2: onboard WiFi (AW859A/UWE5622) + Bluetooth + Docker\",\"auto_init\":false}" \
		>/dev/null
	echo "  已创建"
fi

echo ">>> 3/6 提交本地代码"
cd "$ROOT"
[ -d .git ] || git init -q
# Windows 上 git 不记可执行位，交给 diy.sh 在 CI 里补，这里关掉 fileMode 检查避免噪声
git config core.fileMode false
# 没有全局身份时用临时的，不污染用户配置
GO="git -c user.name=${GIT_AUTHOR_NAME:-openwrt-builder} -c user.email=${GIT_AUTHOR_EMAIL:-builder@example.com}"
git checkout -q -B main 2>/dev/null || $GO checkout -q -B main
git add -A
if git diff --cached --quiet; then
	echo "  没有新改动"
else
	$GO commit -q -m "OpenWrt 24.10 for Orange Pi Zero 2: AW859A WiFi + BT + Docker"
	echo "  已提交"
fi

echo ">>> 4/6 推送"
git remote remove origin 2>/dev/null || true
git remote add origin "https://github.com/$LOGIN/$REPO_NAME.git"
# credential.helper 显式清空：否则某些 Windows 环境下安装的凭据管理器会把
# 这次 URL 里的 token 持久化进系统凭据库，那就违背了"用完即弃"的承诺。
$GO -c credential.helper= push -q -f \
	"https://x-access-token:$TOKEN@github.com/$LOGIN/$REPO_NAME.git" main
echo "  已推送到 https://github.com/$LOGIN/$REPO_NAME"

echo ">>> 5/6 触发编译"
# push 已经会触发（workflow 里配了 push: main），这里再显式 dispatch 一次保证一定有
sleep 5
curl -fsSL -X POST \
	"$API/repos/$LOGIN/$REPO_NAME/actions/workflows/build.yml/dispatches" \
	-H "Authorization: Bearer $TOKEN" \
	-H "Accept: application/vnd.github+json" \
	-d '{"ref":"main"}' >/dev/null && echo "  已触发" || echo "  触发失败（可能 push 事件已经在跑了，去 Actions 页面看看）"

RUN_URL="https://github.com/$LOGIN/$REPO_NAME/actions"
echo
echo "========================================================"
echo "  进度看这里： $RUN_URL"
echo "  编译约 40~90 分钟（首次全量）"
echo "========================================================"
echo

echo ">>> 6/6 锁定本次触发的 run id"
# 关键：必须按 id 跟踪，不能按"最新一次运行"。否则之后任何一个 commit
# （哪怕只改了 README）触发新运行，轮询就会切过去，等到的是别人的结论。
sleep 8
RUNID="$(python3 - <<PY
import json, os, urllib.request
T = os.environ['TOKEN']
hdr = {'Authorization': 'Bearer ' + T, 'Accept': 'application/vnd.github+json'}
def get(p):
    r = urllib.request.Request('https://api.github.com' + p, headers=hdr)
    with urllib.request.urlopen(r) as x:
        return json.loads(x.read() or b'{}')
rs = get('/repos/$LOGIN/$REPO_NAME/actions/runs?branch=main&per_page=10').get('workflow_runs', [])
# 取 head_sha 与本地产出提交一致的最新一次
mine = os.popen('git -C "$ROOT" rev-parse HEAD').read().strip()
cand = [r for r in rs if r['head_sha'] == mine]
print((cand[0] if cand else (rs[0] if rs else {'id': ''}))['id'])
PY
)"
if [ -z "$RUNID" ]; then
	echo "  !! 没定位到 run id，去 $RUN_URL 手动看吧"
	exit 1
fi
echo "  run id = $RUNID"

echo ">>> 等待编译结束（每 60 秒查一次，Ctrl-C 可以随时退出，不影响云端任务）"
GITHUB_TOKEN="$TOKEN" GITHUB_REPO="$LOGIN/$REPO_NAME" \
	bash "$ROOT/tools/wait.sh" "$RUNID"
