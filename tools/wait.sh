#!/usr/bin/env bash
#
# 等待指定的某次 Actions 运行结束，成功后把产物下载到 dist/
#
# 用法：
#   GITHUB_TOKEN=ghp_xxx bash tools/wait.sh 38395119942
#   GITHUB_TOKEN=ghp_xxx bash tools/wait.sh            # 不传则取当前分支最新一次运行
#
# 为什么单独拆出来：publish.sh 早期版本用 "runs?per_page=1" 取最新一次运行，
# 但只要之后任何一个 commit 触发了新运行，轮询就会切到那次运行上——
# 于是"等到 completed"和"自己触发的编译"根本不是同一次，结论完全是错的。
# 所以这里必须以 run id 为准。
#
set -uo pipefail

TOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPO:-jjyjul-cmyk/opi-zero2-openwrt}"
RUN_ID="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INTERVAL="${POLL_INTERVAL:-60}"

[ -n "$TOKEN" ] || { echo "!! 请先设置 GITHUB_TOKEN"; exit 1; }

export TOKEN REPO RUN_ID

# 一次 API 调用同时拿到运行状态；用 python 解析，避免 sed 正则被 JSON 字段顺序变化打崩
state() {
	python3 - "$@" <<'PY'
import json, os, sys, urllib.request
T = os.environ['TOKEN']; REPO = os.environ['REPO']
rid = os.environ.get('RUN_ID') or ''
def api(path):
	req = urllib.request.Request('https://api.github.com' + path)
	req.add_header('Authorization', 'Bearer ' + T)
	req.add_header('Accept', 'application/vnd.github+json')
	with urllib.request.urlopen(req) as r:
		return json.loads(r.read() or b'{}')

if not rid:
	d = api(f'/repos/{REPO}/actions/runs?per_page=1')
	rs = d.get('workflow_runs', [])
	if not rs:
		print('NOTFOUND'); sys.exit(0)
	rid = str(rs[0]['id'])

run = api(f'/repos/{REPO}/actions/runs/{rid}')
print(f"{run['status']}|{run['conclusion']}|{rid}|{run.get('head_sha','')[:7]}|{run['html_url']}")
PY
}

if [ -z "$RUN_ID" ]; then
	LINE="$(state)" || { echo "!! 查询失败，检查 token"; exit 1; }
	RUN_ID="$(echo "$LINE" | cut -d'|' -f3)"
	[ "$RUN_ID" != "NOTFOUND" ] || { echo "!! 该仓库还没有任何运行"; exit 1; }
fi
export RUN_ID

echo ">>> 跟踪 run $RUN_ID （每 ${INTERVAL}s 查一次）"

while true; do
	LINE="$(state)" || { sleep "$INTERVAL"; continue; }
	ST="$(echo "$LINE" | cut -d'|' -f1)"
	CC="$(echo "$LINE" | cut -d'|' -f2)"
	SHA="$(echo "$LINE" | cut -d'|' -f4)"
	URL="$(echo "$LINE" | cut -d'|' -f5)"

	# 顺手报一下当前走到哪一步，便于判断"卡住"还是"在编"
	STEP="$(python3 - <<'PY'
import json, os, urllib.request
T = os.environ['TOKEN']; REPO = os.environ['REPO']; rid = os.environ['RUN_ID']
req = urllib.request.Request(f'https://api.github.com/repos/{REPO}/actions/runs/{rid}/jobs')
req.add_header('Authorization', 'Bearer ' + T)
req.add_header('Accept', 'application/vnd.github+json')
try:
	with urllib.request.urlopen(req) as r:
		j = json.loads(r.read())
	for job in j.get('jobs', []):
		for s in job.get('steps', []):
			if s['status'] == 'in_progress':
				print(f"{s['number']}/{len(job['steps'])} {s['name']}")
				raise SystemExit
except SystemExit:
	pass
except Exception:
	pass
PY
)"

	printf '  [%s] %s %s %s  %s\n' "$(date +%H:%M:%S)" "$ST" "$SHA" "${CC:-null}" "$STEP"

	if [ "$ST" = "completed" ]; then
		mkdir -p "$ROOT/dist"
		# 成败都下载：失败时 artifacts 里是"失败日志"，那是排查的全部依据。
		#
		# 下载必须用 curl 而不是 python urllib：产物接口会 302 跳到
		# objects.githubusercontent.com 这类 blob 主机，urllib 在跟随时会把
		# Authorization 头一起带过去，blob 主机不认这个头 → 401。
		# curl 默认【不】跨主机转发认证，所以直接 -L 就能拿到。
		python3 - >"$ROOT/dist/.artifacts" <<'PY'
import json, os, urllib.request
T = os.environ['TOKEN']; REPO = os.environ['REPO']; rid = os.environ['RUN_ID']
req = urllib.request.Request(f'https://api.github.com/repos/{REPO}/actions/runs/{rid}/artifacts')
req.add_header('Authorization', 'Bearer ' + T)
req.add_header('Accept', 'application/vnd.github+json')
with urllib.request.urlopen(req) as r:
    arts = json.loads(r.read() or b'{}').get('artifacts', [])
if not arts:
    print('__NONE__')
for a in arts:
    # id \t name \t size
    print(f"{a['id']}\t{a['name']}\t{a['size_in_bytes']}")
PY
		if grep -q '__NONE__' "$ROOT/dist/.artifacts"; then
			echo "  (这次运行没有上传任何 artifact)"
		else
			while IFS="$(printf '\t')" read -r aid aname asize; do
				[ -n "$aid" ] || continue
				zp="$ROOT/dist/artifact-$aid-$aname.zip"
				if curl -fsSL -H "Authorization: Bearer $TOKEN" \
					"https://api.github.com/repos/$REPO/actions/artifacts/$aid/zip" -o "$zp"; then
					printf '  %s  (%s, %s)\n' "$(basename "$zp")" \
						"$(du -h "$zp" | cut -f1)" "$aname"
					unzip -o -q "$zp" -d "$ROOT/dist/" 2>/dev/null \
						&& echo "    已解压: $(unzip -Z1 "$zp" | head -6 | tr '\n' ' ')"
				else
					echo "  !! $aname 下载失败（HTTP 错误）"
				fi
			done < "$ROOT/dist/.artifacts"
		fi
		rm -f "$ROOT/dist/.artifacts"
		echo
		if [ "$CC" = "success" ]; then
			echo ">>> 编译成功。产物在 $ROOT/dist/"
			ls -lh "$ROOT/dist/" 2>/dev/null | tail -n +2
			exit 0
		else
			echo "!! 编译结论： $CC"
			echo "!! 日志： $URL"
			exit 1
		fi
	fi
	sleep "$INTERVAL"
done
