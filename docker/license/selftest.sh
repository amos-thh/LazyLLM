#!/usr/bin/env bash
# =============================================================================
# _launcher.so 许可守护自检 (在 docker/license 目录下运行, 本机需能跑 docker)
#
#   ./selftest.sh                  # 跑 1~3 (faketime 有则自动测第 4 项)
#
# 测试项:
#   [1] 正常生命周期: run() 通过, 巡检节奏正确(±容差内)全程存活
#   [2] 时间跳变(漂移): 两次巡检间隔超过 [interval-tol, interval+tol] -> _exit(1)
#   [3] 运行中过期: 越过 expiry 后下一次 check() -> _exit(1)
#   [4] 时钟定格(可选): 依赖 libfaketime 的 faketime 命令, 无则 SKIP
#
# 注意: 本脚本会临时编一个 12s 窗口的自检 .so 来跑 1~3, 测完自动
#       恢复目录里原有的 _launcher*.so (不破坏你编好的生产窗口 .so)。
#       build_license.py 的授权单位 (days*86400 或 days*60) 会自动识别。
# =============================================================================
set -u
cd "$(dirname "$0")"

PASS=0; FAIL=0
say() { printf '%s\n' "$*"; }
ok()   { say "[PASS] $1"; PASS=$((PASS+1)); }
bad()  { say "[FAIL] $1"; FAIL=$((FAIL+1)); }

# ---- 0. 准备: 探测单位, 编 12s 窗口自检 .so, 暂存现有 .so ----
ORIG_SO=$(ls _launcher.cpython-*.so 2>/dev/null | head -1)
UNIT=$(python -c 'import re;src=open("build_license.py",encoding="utf-8").read();m=re.search(r"^    max_interval = int\(args\.days \* (\d+)\)",src,re.M);print(m.group(1) if m else 86400)')
W=20
DAYS=$(python -c "print('%.6f' % (float($W)/$UNIT))")
say "[selftest] build_license 单位 = days*$UNIT, 自检窗口 ${W}s (days=$DAYS)"
say "[selftest] 构建自检 .so (巡检 3s 容差 1s) ..."
if [ -n "$ORIG_SO" ]; then mv "$ORIG_SO" "${ORIG_SO}.stash"; fi
if ! PLATFORM=${PLATFORM:-linux/arm64} ./build.sh "$DAYS" 3 1 >/dev/null 2>&1; then
  [ -n "$ORIG_SO" ] && mv "${ORIG_SO}.stash" "$ORIG_SO" 2>/dev/null
  say "[FAIL] 自检 .so 构建失败 (见上方 build.sh 输出)"
  exit 1
fi
TEST_SO=$(ls _launcher.cpython-*.so | head -1)
trap 'rm -f "$TEST_SO"; [ -n "$ORIG_SO" ] && mv "${ORIG_SO}.stash" "$ORIG_SO" 2>/dev/null' EXIT

DRIVER=$(mktemp)
cat > "$DRIVER" <<'PY'
import sys, time
sys.path.insert(0, '/license')
import _launcher as L

mode = sys.argv[1]
if mode == 'normal':
    L.run()
    t0 = time.time()
    for i in range(4):
        time.sleep(2)
        L.check()
    print('LIVED %.0fs' % (time.time() - t0))
elif mode == 'drift':
    L.run(); L.check(); time.sleep(6); L.check()   # 6s > 3+1 -> 必须死
    print('SURVIVED')
elif mode == 'expire':
    L.run()
    while time.time() < L.expiry(): time.sleep(0.2)
    time.sleep(0.5)
    L.check()                                      # 已过 expiry -> 必须死
    print('SURVIVED')
PY
W=$(cygpath -w "$(pwd)" 2>/dev/null || pwd)
RUN() { docker run --rm -i --platform "${PLATFORM:-linux/arm64}" \
         -v "$(cygpath -w "$(pwd)" 2>/dev/null || echo "$(pwd)"):/license" -w /license \
         "${BUILDER_IMAGE:-license-builder:bookworm-gcc-arm64}" python "/license/$(basename "$DRIVER")" "$1"; }

# ---- [1] 正常 ----
say "[1] 正常生命周期: run() + 4 次巡检"
LIVE=$(RUN normal || echo DIED)
if echo "$LIVE" | grep -q '^LIVED [0-9]'; then ok "[1]"; else bad "[1] 输出=$LIVE"; fi

# ---- [2] 时间跳变 ----
say "[2] 时间跳变: 巡检间隔 6s 超过 [2s,4s] -> 应 _exit(1)"
if RUN drift 2>/dev/null; then bad "[2] 未退出"; else ok "[2] 已退出"; fi

# ---- [3] 运行中过期 ----
say "[3] 运行中过期: 越过 expiry 后下一次 check() -> 应 _exit(1)"
if RUN expire 2>/dev/null; then bad "[3] 未退出"; else ok "[3] 已退出"; fi

# ---- [4] 时钟定格 (可选) ----
if command -v faketime >/dev/null 2>&1; then
  say "[4] 时钟定格: faketime 设到过去 -> run() 应 _exit(1)"
  FT=$(command -v faketime)
  if faketime '2020-01-01 00:00:00' docker run --rm -i --platform "${PLATFORM:-linux/arm64}" \
       -v "$(cygpath -w "$(pwd)" 2>/dev/null || echo "$(pwd)"):/license" -w /license \
       "${BUILDER_IMAGE:-license-builder:bookworm-gcc-arm64}" \
       sh -c "faketime '2020-01-01 00:00:00' python -c 'import sys;sys.path.insert(0,\"/license\");import _launcher as L;L.run()'" 2>/dev/null; then
    bad "[4] 未拒启"
  else ok "[4] 已拒启"; fi
else
  say "[SKIP] [4] 无 libfaketime (apt install faketime 后重试)"
fi

rm -f "$DRIVER"
say "=========================================="
say "结果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]