#!/usr/bin/env bash
# 开发环境：一条命令起服务，数据与配置都留在 .dev/ 里（已被 gitignore）。
#
# 用法：
#   ./scripts/dev.sh                  # 起服务（前台；装了 cargo-watch 就改代码自动重启）
#   ./scripts/dev.sh status           # 看当前状态（服务 / worker / 编码 / 设备 / 数据量 / 构建缓存）
#   ./scripts/dev.sh status --size    # 重新统计构建缓存体积（要扫 target/debug，几秒）
#   ./scripts/dev.sh client           # 起 Flutter 客户端（默认本机桌面平台）
#   ./scripts/dev.sh client -d chrome # 额外参数原样传给 flutter run
#   ./scripts/dev.sh client android   # 把最新包推到安卓开发机（默认 release，装完自动拉起）
#   ./scripts/dev.sh client android debug   # 同上但 debug 包：可热重载（改手机端 UI 用）
#   ./scripts/dev.sh client android emulator # 用安卓模拟器：自动 debug，走 adb reverse 回环（服务只绑
#                                          # 127.0.0.1 也能自动配对）；真机在插时用这个才不会撞"多台设备"
#   ./scripts/dev.sh client android -d <id> # 多台安卓设备时显式指定，其余参数透传给 flutter run
#   ./scripts/dev.sh client ios       # 同上，推到 iPhone（默认 release；有真机选真机，只有一台模拟器
#                                    # 时自动用它并切 debug）
#   ./scripts/dev.sh client ios simulator   # 强制用 iOS 模拟器（自动 debug；只有一台时不必给 -d）
#   ./scripts/dev.sh client ios device      # 强制用 iOS 真机（默认就是真机优先）
#   ./scripts/dev.sh client ios debug # iOS 调试：debug 包只能由本命令/IDE 拉起，点图标不行
#   ./scripts/dev.sh client ios profile     # 能从桌面图标独立启动，且带基本性能采样
#
# 模拟器/模拟设备走回环地址配对（服务不用改绑 0.0.0.0）；真机仍用局域网地址。
#
# client 启动时会顺带注入服务地址与一张一次性配对码：客户端如果连不上本地配置，
# 就用这组参数自动配对（本机确认由脚本代劳），省掉手填地址、抄码、勾指纹。
# 只在 debug 运行注入——release/profile 是产物，码会被打进包。
#   ./scripts/dev.sh pair             # 生成配对码（输出里带客户端该填的地址）
#   ./scripts/dev.sh pair --list      # 看待确认请求
#   ./scripts/dev.sh pair --approve <id>
#   ./scripts/dev.sh pair reset       # 吊销全部设备（默认只打印清单）
#   ./scripts/dev.sh pair reset --yes # 确认执行：所有设备令牌立即作废
#   ./scripts/dev.sh plugin install <zip>  # 装技能包（.zip）；也可以 list / enable / disable / remove
#   ./scripts/dev.sh plugin restore        # 恢复预置技能（trip-plan / bill-explain，卸载过也能装回）
#   ./scripts/dev.sh stop             # 停掉没关掉的 dev 服务（终端关了、Ctrl-C 没按）
#   ./scripts/dev.sh restart          # 重启（先停再起，端口沿用配置里的那个）
#   ./scripts/dev.sh reset            # 删掉 .dev/data，从零开始
#   ./scripts/dev.sh clean            # 清掉 target/debug（dev 产物；release 不动）
#
# 与 release 的区别只有"配置和启动方式"，二进制与业务语义完全一致——
# 不提供改安全默认值的 --dev 开关，避免"dev 能跑、prod 炸"的第二条路径。
#
# 可用的环境变量：
#   AGENT_PORT=8790            指定首选端口（被占用时会自动往后找）
#   AGENT_BIND=0.0.0.0         监听地址（默认 127.0.0.1；改成非回环即自动启用自签 TLS）
#   AGENT_TLS=auto             传输策略 auto|on|off（off 只允许回环，否则服务拒绝启动）
#   AGENT_ALLOW_HOSTS              已废弃：域名白名单已移除（公网地址默认可读，内网仍拒绝）
#   AGENT_CODE_ROOTS=$HOME/code    开启编码任务并指定允许的仓库根（逗号分隔）
#   AGENT_CODE_PROVIDER=codebuddy  编码 CLI（opencode | codebuddy，默认 opencode）
#   AGENT_CODE_BIN=/path/opencode  指定 CLI 路径（默认走 PATH）
#   AGENT_PROJECT_ROOTS=$HOME      允许浏览/挂载为项目的根目录（逗号分隔）
#                                  （旧名 AGENT_WORKSPACE_ROOTS 仍兼容）
#   AGENT_BROWSER_PORTS=3000,5173  浏览器面板允许访问的服务端回环端口（逗号分隔）
#   PERSONAL_AGENT_LLM_API_KEY=... 有值就自动在 dev 配置里开启模型
#   AGENT_LLM_MODEL=qwen3-vl-plus  dev 用哪个模型（不写就沿用上次配置里的）
#   AGENT_LLM_VISION=0             关掉读图（**dev 默认开启**：附件里的图片
#                                  以多模态片段送模型；模型必须支持 image_url，
#                                  否则附图的轮次会报生成中断）
#
# .dev/config.json 里 dev 不认识的键（例如手写的 "memory" 段）会被保留：
# 每次启动只重写 data_dir/api_bind/tls/llm/asr/tts/tool/code/project/browser 这几项。
# `llm` 段是逐字段合并的：手写的 vision / model / base_url 不会被清掉。
#
# 本机默认值写在 .dev/env（已在 gitignore 里）：一行一个 KEY=VALUE。
# 优先级：命令行环境变量 > .dev/env > 脚本内置默认值。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${ROOT}/.dev"
ENV_FILE="${DEV_DIR}/env"

# .dev/env 只补缺省，命令行显式给的值优先。source 会无条件覆盖同名变量，
# 所以先把"父进程已经给了值"的键记下来，读完文件再盖回去。
# 新增变量时记得同步这个列表（只用普通变量：macOS 自带的是 bash 3.2，没有关联数组）。
ENV_KEYS="AGENT_PORT AGENT_BIND AGENT_TLS AGENT_CODE_ROOTS AGENT_CODE_PROVIDER AGENT_CODE_BIN AGENT_PROJECT_ROOTS AGENT_WORKSPACE_ROOTS AGENT_BROWSER_PORTS AGENT_LLM_VISION AGENT_LLM_MODEL PERSONAL_AGENT_LLM_API_KEY"
for key in ${ENV_KEYS}; do
  if [[ -n "${!key:-}" ]]; then
    printf -v "CLI_${key}" '%s' "${!key}"
  fi
done

# 配置每次启动都重写，所以"每次都要敲的变量"应该落在这里。
# set -a 是必须的：PERSONAL_AGENT_LLM_API_KEY 由服务进程自己从环境读，
# 不导出的话写在文件里也不生效。
if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  set +a
fi

for key in ${ENV_KEYS}; do
  saved="CLI_${key}"
  if [[ -n "${!saved:-}" ]]; then
    printf -v "${key}" '%s' "${!saved}"
    export "${key}"
  fi
done

DATA_DIR="${DEV_DIR}/data"
CONFIG="${DEV_DIR}/config.json"
SERVICE_BIN="${ROOT}/target/debug/jarvis-service"
DEFAULT_PORT="${AGENT_PORT:-8787}"
BIND_HOST="${AGENT_BIND:-127.0.0.1}"
TLS_MODE="${AGENT_TLS:-auto}"
PORT_SCAN_LIMIT=10

# --- 地址事实源 ---------------------------------------------------------------
#
# 取"服务到底绑在哪、用什么协议"时，一律**配置优先、环境变量兜底**：
# 配置是上次真正启动时写下的（服务没跑时也读得到），而 AGENT_BIND/AGENT_TLS
# 只在本次命令行里有效。只看环境变量会在停服时打出 127.0.0.1:8787 这种
# 和实际配置无关的地址——比不打印更误导。
#
# 这些函数都只往 stdout 输出供 $(...) 捕获，不要在里面打提示。

# 配置里的 api_bind（形如 `0.0.0.0:8788`），读不到输出空串。
config_api_bind() {
  [[ -f "${CONFIG}" ]] || return 0
  sed -n 's/.*"api_bind": *"\([^"]*\)".*/\1/p' "${CONFIG}" 2>/dev/null | head -1 || true
}

# 配置里 tls.mode 的 on|off|auto，读不到输出空串。
config_tls_mode() {
  [[ -f "${CONFIG}" ]] || return 0
  sed -n '/"tls"[[:space:]]*:[[:space:]]*{/,/}/ s/.*"mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' \
    "${CONFIG}" 2>/dev/null | head -1 || true
}

# 实际绑定用的 host：配置优先，其次本次环境变量。
bound_host() {
  local bind
  bind="$(config_api_bind)"
  if [[ -n "${bind}" ]]; then
    printf '%s' "${bind%:*}"
  else
    printf '%s' "${BIND_HOST}"
  fi
}

# 与服务的判定保持一致：回环 + auto 是明文，非回环 + auto 是 TLS。
is_loopback_bind() {
  case "$(bound_host)" in
    127.*|localhost|::1|"[::1]") return 0 ;;
    *) return 1 ;;
  esac
}

# 客户端该用的协议：tls.mode 显式 on/off 就照办，auto 时按绑定地址推。
bound_scheme() {
  local mode
  mode="$(config_tls_mode)"
  [[ -n "${mode}" ]] || mode="${TLS_MODE}"
  case "${mode}" in
    on) printf 'https' ;;
    off) printf 'http' ;;
    *)
      if is_loopback_bind; then printf 'http'; else printf 'https'; fi
      ;;
  esac
}

address_scheme() { bound_scheme; }

# 本机默认出口地址（局域网 IPv4），取不到输出空串。
#
# 只用默认路由那张网卡：Wi-Fi/USB 网卡/虚拟机网桥同时存在时，
# 列一堆地址反而要用户自己猜哪个能连。服务端 tls::detect_lan_ip() 也是
# 同一口径（出口地址），两边不一致会出现"证书 SAN 里有、面板里没有"。
lan_ipv4() {
  local iface="" ip=""
  case "$(uname -s)" in
    Darwin)
      iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
      [[ -n "${iface}" ]] || iface="en0"
      ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
      if [[ -z "${ip}" ]]; then
        # 没有默认路由（如只连了对等网线）时退一步扫一遍，跳过回环。
        ip="$(ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {print $2; exit}')"
      fi
      ;;
    Linux)
      ip="$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')"
      if [[ -z "${ip}" ]]; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      fi
      ;;
  esac

  case "${ip}" in
    ""|127.*|::1) return 0 ;;
    *) printf '%s' "${ip}" ;;
  esac
}

info() { printf '\033[36m›\033[0m %s\n' "$1"; }
# 警告必须走 stderr：pick_port 的结果是用 $(...) 取的，混进 stdout 会被当成端口值
warn() { printf '\033[33m!\033[0m %s\n' "$1" >&2; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# 文件头的注释就是帮助文本：打到第一行非注释为止。
# 不写死行号——往上面加一行变量说明就漏印，是已经踩过的坑。
print_help() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

port_in_use() {
  # -sTCP:LISTEN：只关心"有进程在监听"，不把客户端连接误判成占用
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# 当前实际端口：服务活着时以 api.port 为准（api_bind 端口写 0 时由系统分配），
# 否则退回配置里写的那个。
current_port() {
  local port=""
  if [[ -f "${DATA_DIR}/api.port" ]]; then
    port="$(tr -dc '0-9' <"${DATA_DIR}/api.port" 2>/dev/null || true)"
  fi
  if [[ -z "${port}" && -f "${CONFIG}" ]]; then
    port="$(sed -n 's/.*"api_bind": *"[^"]*:\([0-9]\{1,5\}\)".*/\1/p' "${CONFIG}" | head -1)"
  fi
  printf '%s' "${port:-unknown}"
}

# 端口：优先命令行环境变量，其次上次写进配置的端口，最后默认 8787。
# 被占用就往后找，找到后把实际端口写进配置——客户端只需照 pair 打印的地址填。
pick_port() {
  local port="${DEFAULT_PORT}"
  if [[ -f "${CONFIG}" && -z "${AGENT_PORT:-}" ]]; then
    local previous
    previous="$(sed -n 's/.*"api_bind": *"[^"]*:\([0-9]\{1,5\}\)".*/\1/p' "${CONFIG}" | head -1)"
    [[ -n "${previous}" ]] && port="${previous}"
  fi

  local candidate="${port}"
  local tries=0
  while port_in_use "${candidate}"; do
    tries=$((tries + 1))
    if (( tries >= PORT_SCAN_LIMIT )); then
      fail "从 ${port} 起连续 ${PORT_SCAN_LIMIT} 个端口都被占用；用 AGENT_PORT=xxxx 指定一个空闲端口"
    fi
    candidate=$((candidate + 1))
  done

  if [[ "${candidate}" != "${port}" ]]; then
    warn "端口 ${port} 已被占用（可能装过服务并在跑），本次改用 ${candidate}"
  fi
  printf '%s' "${candidate}"
}

write_config() {
  local port="$1"
  mkdir -p "${DATA_DIR}"
  # 技能包安装目录。`./scripts/dev.sh plugin install <zip>` 会把包装到这里，
  # 也可以手工解压成 plugins/<id>/<version>/skills/<name>/SKILL.md 调试加载。
  mkdir -p "${DATA_DIR}/plugins"
  # 旧名 AGENT_WORKSPACE_ROOTS 继续兼容：新名没给时沿用它。
  local project_roots="${AGENT_PROJECT_ROOTS:-${AGENT_WORKSPACE_ROOTS:-}}"
  # 用 python3 生成 JSON：路径里有空格或中文时手拼 printf 很容易写坏
  python3 - "${CONFIG}" "${DATA_DIR}" "${BIND_HOST}:${port}" "${TLS_MODE}" \
    "${PERSONAL_AGENT_LLM_API_KEY:+1}" "${BAILIAN_API_KEY:+1}" \
    "${AGENT_CODE_ROOTS:-}" "${AGENT_CODE_PROVIDER:-}" "${AGENT_CODE_BIN:-}" "${project_roots}" \
    "${AGENT_BROWSER_PORTS:-}" "${AGENT_LLM_VISION:-}" "${AGENT_LLM_MODEL:-}" <<'PY'
import json
import sys

(path, data_dir, bind, tls_mode, has_key, has_bailian, code_roots, code_provider,
 code_bin, project_roots, browser_ports, llm_vision, llm_model) = sys.argv[1:14]
# dev 自己管的键：本次没给就删掉（例如撤掉 AGENT_CODE_ROOTS 后不该残留旧的 code 段）。
# 别的键（例如手写的 "memory"）一律保留——**dev 不该吃掉用户手改的配置**。
# "workspace" 是改名前旧配置里的段名：写新配置时一并删掉，否则 serde 会把它
# 和新的 "project" 当成同一个字段的两次赋值。
#
# "tool" 刻意**不**在这里：工具额度（轮数、检索次数、超时）是用户按自己机器与
# 使用习惯调的，dev 每次启动把它清掉，等于"改了也没用"。它没有 dev 专属默认值，
# 缺字段时服务端会取 `ToolConfig::default()`，保留即可。
MANAGED = {
    "data_dir", "api_bind", "tls", "llm", "asr", "tts",
    "code", "project", "workspace", "browser",
}
try:
    with open(path, encoding="utf-8") as handle:
        previous = json.load(handle)
    if not isinstance(previous, dict):
        previous = {}
except (OSError, ValueError):
    previous = {}

config = {key: value for key, value in previous.items() if key not in MANAGED}
config.update({
    "data_dir": data_dir,
    "api_bind": bind,
    # 显式写入而不是靠默认值：dev 看到的行为必须就是配置里的行为。
    "tls": {"mode": tls_mode},
})
if has_key:
    # `llm` 段整体由 dev 管，但**逐字段合并**而不是整段盖掉：
    # `vision` / `model` / `base_url` 这些是用户手调的行为开关（例如换成读图模型），
    # 每次启动都被清回默认值，等于"改了也没用"——和 "tool" 段同一个理由。
    # 想改回来就用环境变量，dev 下次启动会把新值写回配置。
    previous_llm = previous.get("llm")
    if not isinstance(previous_llm, dict):
        previous_llm = {}
    llm = {
        "enabled": True,
        "api_key_env": "PERSONAL_AGENT_LLM_API_KEY",
    }
    # `api_path` / `active` / `profiles` 是客户端模型配置写下的：dev 每次重启
    # 都把它们清掉，等于"在客户端里配好的第三方模型一重启就消失"。
    for key in ("base_url", "model", "timeout_ms", "stream_idle_timeout_ms", "vision",
                "api_path", "active", "profiles"):
        if key in previous_llm:
            llm[key] = previous_llm[key]
    # 优先级：显式环境变量 > 上次写下的值 > **dev 默认开**。
    # dev 默认开是有意的：附件功能要跑起来就得能看图，让每个开发者先撞一次
    # "只能看到文件名"再回来翻代码，成本比一句提示高得多。
    if llm_vision:
        llm["vision"] = llm_vision not in ("0", "false", "off", "no")
    elif "vision" not in llm:
        llm["vision"] = True
    if llm_model:
        llm["model"] = llm_model
    config["llm"] = llm

    # 开了 vision 但模型明显不是读图模型时给一句提示：否则附图的轮次会被上游
    # 直接拒掉，用户看到的是"生成中断"，很难联想到是模型选错了。
    # 配置里没写 model 时也要提示——那意味着走服务端内置默认值（纯文本模型），
    # 正是最容易"开了却没生效"的那条路。
    model = str(llm.get("model") or "")
    looks_vision = any(tag in model.lower() for tag in ("vl", "vision", "omni"))
    if llm.get("vision") and not looks_vision:
        print(
            "  提示：llm.vision 已开启，但当前模型（"
            + (model or "服务端内置默认值")
            + "）看起来不支持读图；附图片的轮次会被上游拒绝。"
            "要真正读图请用 AGENT_LLM_MODEL=<支持 image_url 的模型> 启动一次。",
            file=sys.stderr,
        )
if has_bailian:
    # 转写与合成用百炼的 Key（与对话网关不是同一把）：没有它就不写这两段，
    # 录音只归档、不出文本，也不会因为"开了但没钥匙"把服务卡在启动自检。
    config["asr"] = {
        "enabled": True,
        "provider": "multimodal",
        "model": "qwen-audio-3.1-asr-flash",
        "api_key_env": "BAILIAN_API_KEY",
    }
    # 总结语音与转写共用同一把百炼 Key；关闭时只是不出语音。
    config["tts"] = {
        "enabled": True,
        "model": "qwen-audio-3.1-tts-flash",
        "api_key_env": "BAILIAN_API_KEY",
    }
if code_roots:
    code = {
        "enabled": True,
        "allow_roots": [r.strip() for r in code_roots.split(",") if r.strip()],
    }
    if code_provider:
        code["provider"] = code_provider
    if code_bin:
        code["bin"] = code_bin
    config["code"] = code
if project_roots:
    config["project"] = {
        "browse_roots": [r.strip() for r in project_roots.split(",") if r.strip()],
    }
if browser_ports:
    # 浏览器面板只放行显式列出的回环端口：默认值在服务端代码里，
    # dev 想临时多加一个端口时用它，不用手改 .dev/config.json。
    config["browser"] = {
        "allowed_ports": [
            int(port.strip()) for port in browser_ports.split(",") if port.strip()
        ],
    }
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
PY
}

print_next_steps() {
  local port="$1"
  local scheme
  scheme="$(address_scheme)"
  echo
  info "数据目录：${DATA_DIR}"
  info "监听地址：${BIND_HOST}:${port}（${scheme}，tls.mode=${TLS_MODE}）"
  # 本机 + 局域网两行红字：客户端配对时照抄，手机端尤其需要局域网那条。
  print_service_addresses "${port}"
  if ! is_loopback_bind; then
    # 地址已经在上面给过了，这里只补"局域网可达"带来的安全前提。
    warn "局域网内其他设备可访问：客户端首次连接必须核对证书指纹"
  fi
  echo "  下一步（另开终端）："
  if [[ -n "${AGENT_CODE_ROOTS:-}" ]]; then
    info "编码任务已启用（CLI：${AGENT_CODE_PROVIDER:-opencode}）；可用作 Git 项目的目录：${AGENT_CODE_ROOTS}"
    info "客户端：新建项目时打开「Git 仓库」→ 选仓库目录 → 派编码任务（只填要改什么）"
  else
    # 未启用是合法的（默认全拒），但结果是静默降级：技能列表里直接没有 code-task，
    # 不说一句就变成了"为什么点了半天找不到"。这里明确告诉你怎么打开。
    info "编码任务未启用：建不了 Git 项目，也不会出现 code-task 技能"
    info "要启用：在 ${ENV_FILE} 写一行 AGENT_CODE_ROOTS=<允许的仓库根>（可逗号分隔多个）"
  fi
  if [[ -n "${AGENT_PROJECT_ROOTS:-${AGENT_WORKSPACE_ROOTS:-}}" ]]; then
    info "项目可挂载的根目录：${AGENT_PROJECT_ROOTS:-${AGENT_WORKSPACE_ROOTS:-}}"
  else
    info "项目默认只能挂载用户主目录；要放开别的目录写 AGENT_PROJECT_ROOTS"
  fi
  echo "    ./scripts/dev.sh pair                                  # 生成配对码 + 证书指纹"
  echo "    cd jarvis-app && flutter run -d macos                   # 客户端（热重载）"
  echo "  停止：当前窗口 Ctrl-C，或在另一个终端 ./scripts/dev.sh stop"
  echo
}

# dev 实例是否已经在跑：用管理面健康检查判断，而不是只看 socket 文件
# （进程崩过会留下 socket 文件，只用 -S 判断会误报）。
dev_running() {
  local socket="${DATA_DIR}/admin.sock"
  [[ -S "${socket}" ]] || return 1
  curl -fsS --unix-socket "${socket}" http://localhost/admin/health 2>/dev/null | grep -q '"ok"'
}

# dev 实例的进程识别。
#
# 三个来源取并集：pid 文件（daemon-kit 写的，最准）+ 配置文件路径 + debug 二进制路径。
# 绝不用 `pkill -f jarvis-service` 这种宽口径——安装版服务也叫这个名字，
# 开发脚本把用户的生产实例停掉是不可接受的。
dev_service_pids() {
  local pid_file="${DATA_DIR}/personalagent.jarvis-service.pid"
  {
    # ① daemon-kit 写的 pid 文件：最准，但可能指向一个已经退出的进程（被强杀过）。
    if [[ -f "${pid_file}" ]]; then
      local pid
      pid="$(tr -dc '0-9' <"${pid_file}" 2>/dev/null || true)"
      if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
        printf '%s\n' "${pid}"
      fi
    fi

    # ② 命令行兜底：pid 文件缺失、过期，或者同时起了多个实例时都要能认出来。
    #    ./scripts/dev.sh 起的带 --config <abs>/.dev/config.json；手动或 IDE 起的可能
    #    用相对路径（--config config.json），那就认二进制——debug 二进制只存在于本仓库，
    #    release 装的是 /usr/local/bin/jarvis-service，不会被误杀。
    pgrep -f -- "--config ${CONFIG}" 2>/dev/null || true
    pgrep -f -- "${ROOT}/target/debug/jarvis-service" 2>/dev/null || true
  } | sort -u
}

# cargo-watch 是 dev 的父进程：服务停掉后它仍常驻，下一次文件变动就把服务重新拉起来
# （表现成"怎么都停不掉"）。只匹配带本仓库 crates/ 路径的 watcher。
dev_watcher_pids() {
  pgrep -f -- "cargo(-| )watch .*-w ${ROOT}/crates" 2>/dev/null || true
}

# 强杀之后 socket 与 pid 文件会留在原地：留着会让下一次 serve 的「已在运行」
# 判断与 daemon-kit 的 pid 冲突一起误报，所以这里顺手收掉。
cleanup_dev_leftovers() {
  if dev_running; then
    return 0
  fi
  rm -f "${DATA_DIR}/admin.sock" "${DATA_DIR}/personalagent.jarvis-service.pid"
}

# 给一批 pid 发 TERM，等 5 秒；还没走就 KILL。$1 是日志里的名字。
terminate_pids() {
  local label="$1"
  shift
  local pids=("$@")
  if (( ${#pids[@]} == 0 )); then
    return 0
  fi

  local pid
  for pid in "${pids[@]}"; do
    kill -TERM "${pid}" 2>/dev/null || true
  done

  local waited=0
  local alive
  while (( waited < 50 )); do
    alive=0
    for pid in "${pids[@]}"; do
      if kill -0 "${pid}" 2>/dev/null; then
        alive=1
      fi
    done
    if (( alive == 0 )); then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done

  for pid in "${pids[@]}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      warn "${label} pid ${pid} 5 秒内未退出，强制结束"
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  done
}

# service 被强杀时 worker 会变成孤儿（它自己会重连重试，但已经没人管它了）。
# 只收 socket 指向本 dev 数据目录的那个，同样不碰安装版。
stop_orphan_worker() {
  local pids
  pids="$(pgrep -f -- "jarvis-worker --socket ${DATA_DIR}/worker.sock" 2>/dev/null || true)"
  if [[ -z "${pids}" ]]; then
    return 0
  fi
  # shellcheck disable=SC2086
  terminate_pids "jarvis-worker" ${pids}
  info "已结束遗留的 worker 进程"
}

# 停止 dev 服务。可重复执行：没在跑时只清残留文件，不报错。
stop() {
  local service_pids
  local watcher_pids
  service_pids="$(dev_service_pids)"
  watcher_pids="$(dev_watcher_pids)"

  if [[ -z "${service_pids}" && -z "${watcher_pids}" ]]; then
    # 服务已经不在，但 worker 可能还挂着（service 被外部强杀过）。
    stop_orphan_worker
    cleanup_dev_leftovers
    info "dev 服务没有在运行（${DATA_DIR}）"
    return 0
  fi

  # 先停 watcher：留着它会在下次文件变动时把刚停掉的服务重新拉起来。
  if [[ -n "${watcher_pids}" ]]; then
    info "停止 cargo-watch（改代码自动重启的父进程）"
    # shellcheck disable=SC2086
    terminate_pids "cargo-watch" ${watcher_pids}
  fi

  if [[ -n "${service_pids}" ]]; then
    info "停止 dev 服务：pid $(printf '%s' "${service_pids}" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    terminate_pids "jarvis-service" ${service_pids}
  fi

  stop_orphan_worker
  cleanup_dev_leftovers
  info "已停止。数据保留在 ${DATA_DIR}；重新启动：./scripts/dev.sh"
}

# 等端口真的释放。
#
# 进程退出后内核回收监听有一小段延迟；紧接着启动会让 pick_port 扫到"被占用"
# 而换到下一个端口——客户端配对时填的是旧端口，换端口等于连不上。
wait_port_free() {
  local port="$1"
  local waited=0
  while port_in_use "${port}"; do
    if (( waited >= 50 )); then
      warn "端口 ${port} 在 5 秒内未释放；若被别的程序占着，启动会自动换端口（客户端需重填地址）"
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
}

# 重启：先停（含 cargo-watch 与遗留 worker），等端口释放，再按原配置起。
# 数据目录不动，所以配对与历史都不丢；客户端重连即可（流式回答会被打断）。
restart() {
  info "重启 dev 服务"
  stop

  local port
  port="$(current_port)"
  if [[ "${port}" != "unknown" ]]; then
    wait_port_free "${port}"
  fi

  serve
}

# 管理面查询（本地套接字，不需要令牌）。取不到就返回空，让 status 自己降级。
admin_get() {
  curl -fsS --unix-socket "${DATA_DIR}/admin.sock" "http://localhost/admin/$1" 2>/dev/null || true
}

# 管理面写操作。失败返回非 0：调用方要能区分 409（已有活跃票据）这类结果。
admin_post() {
  curl -fsS -X POST --unix-socket "${DATA_DIR}/admin.sock" \
    "http://localhost/admin/$1" 2>/dev/null
}

# --- 开发模式自动配对 ---------------------------------------------------------
#
# 目标：`dev.sh client` 起客户端时顺手把"这次要连哪、用什么码"带进去，
# 客户端连不上时自动配对，省掉手填地址 + 抄码 + 勾指纹。
#
# 边界（很重要）：服务端的配对语义一个字都不改——仍然必须有人在本机确认。
# 这里只是把"人在终端敲 pair --approve"换成本脚本在**同一台机器**上通过
# 本地 unix socket 自动调一次 approve。绝不能把自动批准做进服务端，否则
# 任何拿到配对码的人都能自己批自己，`配对与信任` 里那条不变量就废了。

pair_log() { printf '\033[36m[配对]\033[0m %s\n' "$1"; }

# 指定票据在当前活跃列表里的状态；不在列表里输出空。
pending_status() {
  local request_id="$1"
  admin_get pair/pending | PA_REQUEST="${request_id}" python3 -c '
import json
import os
import sys

raw = sys.stdin.read().strip()
if not raw:
    print("")
    sys.exit(0)
try:
    items = json.loads(raw)
except ValueError:
    print("")
    sys.exit(0)

target = os.environ.get("PA_REQUEST", "")
for item in items:
    if item.get("request_id") == target:
        print(item.get("status", ""))
        break
'
}

# 申请一张开发用票据，输出 `request_id<TAB>code<TAB>expires_at`。
# 失败（典型是已有活跃票据的 409）返回非 0，由调用方降级成"本次不注入"。
dev_pair_start() {
  local body
  body="$(admin_post "pair/start")" || return 1
  printf '%s' "${body}" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
print("%s\t%s\t%s" % (data["request_id"], data["code"], data["expires_at"]))
'
}

# 写 dart-define 文件并输出路径。
#
# 为什么不用 `--dart-define=PA_DEV_PAIR_CODE=...`：那样配对码会出现在 `ps`
# 的输出和本脚本的日志里。文件放 .dev/（已 gitignore）、权限 0600，
# 只有当前用户读得到，配对结束就删。
write_client_pair_file() {
  local url="$1" code="$2" request_id="$3"
  # 文件名带票据 id：两次 `client` 同时开着（桌面 + 安卓）各写各的，
  # 前一轮的守候进程也不会把这一轮的文件当成自己的删掉。
  local path="${DEV_DIR}/client-pairing-${request_id}.json"

  # 一小时前的残留顺手清掉；近期的不动，可能还有 flutter 进程在读它。
  find "${DEV_DIR}" -maxdepth 1 -name 'client-pairing-*.json' -mmin +60 \
    -delete 2>/dev/null || true

  umask 077
  cat >"${path}" <<JSON
{
  "PA_DEV_SERVER_URL": "${url}",
  "PA_DEV_PAIR_CODE": "${code}"
}
JSON
  chmod 600 "${path}" 2>/dev/null || true
  printf '%s' "${path}"
}

# 后台守候：客户端一提交配对码就本机确认。
#
# `$4` 是父进程（exec 之后就是 flutter 自身）的 pid：flutter 一退出就不再等，
# 顺手把没人用的票据收掉，免得它挡住下一次 `pair`。
auto_confirm_pairing() {
  local request_id="$1" expires_at="$2" file="$3" parent="$4"
  local status now

  while kill -0 "${parent}" 2>/dev/null; do
    now=$(( $(date +%s) * 1000 ))
    status="$(pending_status "${request_id}")"

    case "${status}" in
      awaiting_confirmation)
        if admin_post "pair/${request_id}/approve" >/dev/null; then
          pair_log "客户端已提交配对码：已在本机自动确认"
        else
          pair_log "自动确认失败（可能已被本机或其它设备处理）"
        fi
        # 文件不在这里删：flutter 还活着时会用它做增量构建（热重启会重新读），
        # 删掉反而让下一次 rebuild 报 "Did not find the file"。
        return 0
        ;;
      pending)
        if (( now >= expires_at )); then
          admin_post "pair/${request_id}/reject" >/dev/null 2>&1 || true
          pair_log "客户端没有发起配对（多半是本地配置还连得上），配对码已过期回收"
          return 0
        fi
        ;;
      *)
        pair_log "票据已离开等待队列（状态 ${status:-未知}），停止自动配对"
        return 0
        ;;
    esac

    sleep 2
  done

  # flutter 已经退出：这一轮用过的注入文件没人再读了，收掉。
  admin_post "pair/${request_id}/reject" >/dev/null 2>&1 || true
  rm -f "${file}"
}

# 本机可达的服务地址：绑定通配/回环时用 127.0.0.1，绑具体 IP 时照实写。
local_service_url() {
  local scheme host port
  scheme="$(bound_scheme)"
  host="$(bound_host)"
  port="$(current_port)"
  case "${host}" in
    ""|0.0.0.0|::|"[::]") host="127.0.0.1" ;;
  esac
  printf '%s://%s:%s' "${scheme}" "${host}" "${port}"
}

# 参数里是否已有 release 运行：release 产物会把配对码烧进包，一并不注入。
has_release_flag() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --release) return 0 ;;
    esac
  done
  return 1
}

# 注入参数：调用后读全局 CLIENT_DEFINES（空串 = 本次不注入）。
#
# 为什么用全局而不是 `$(client_dev_defines)`：命令替换会等 stdout 的所有写者退出，
# 而这里要在后台 spawn 一个守候进程——它继承同一根管道，替换会一直不返回
# （表现为"卡在启动客户端之前"，实测过一次）。写全局变量则只走主 shell。
#
# 参数 $1 是客户端该连的地址（桌面用 local_service_url，安卓用局域网地址）。
CLIENT_DEFINES=""
client_dev_defines() {
  local url="$1"
  local started request_id code expires_at file

  CLIENT_DEFINES=""
  [[ -n "${url}" ]] || return 0
  dev_running || return 0

  if ! started="$(dev_pair_start)"; then
    warn "已有待确认的配对请求（或申请配对码失败），本次不注入自动配对参数"
    return 0
  fi

  IFS=$'\t' read -r request_id code expires_at <<<"${started}"
  file="$(write_client_pair_file "${url}" "${code}" "${request_id}")"

  ( auto_confirm_pairing "${request_id}" "${expires_at}" "${file}" "$$" & )
  pair_log "已生成配对码：客户端连不上时会自动配上（地址 ${url}）"

  CLIENT_DEFINES="--dart-define-from-file=${file}"
}

# 库里的数据量。缺 sqlite3 就静默跳过：状态输出不该因为少一个工具就报错。
db_counts() {
  local db="${DATA_DIR}/agent.db"
  [[ -f "${db}" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  local row
  row="$(sqlite3 "${db}" \
    "SELECT (SELECT COUNT(*) FROM projects WHERE deleted_at IS NULL) || ' 项目 · ' || (SELECT COUNT(*) FROM conversations WHERE deleted_at IS NULL) || ' 会话 · ' || (SELECT COUNT(*) FROM tasks WHERE deleted_at IS NULL) || ' 任务';" \
    2>/dev/null || true)"
  if [[ -n "${row}" ]]; then
    echo "  数据：${row}"
  fi
}

# KB 转人类可读。bash 3.2（macOS 自带）没有浮点，用整数加半个单位做四舍五入。
human_size() {
  local kb="$1"
  if (( kb >= 1048576 )); then
    printf '%dG' $(( (kb + 524288) / 1048576 ))
  elif (( kb >= 1024 )); then
    printf '%dM' $(( (kb + 512) / 1024 ))
  else
    printf '%dK' "${kb}"
  fi
}

# 构建缓存体积。
#
# target/debug 下只有这两个目录会失控增长（都出现过上百 GB）：deps 是全部产物，
# incremental 是增量编译的会话缓存。不报数字的话，等磁盘满了才发现。
#
# 关键取舍：APFS 不维护"目录总大小"，任何精确数字都得把目录里每个 inode 至少
# stat 一遍（du 只读元数据、不读文件内容，但几十万个文件照样要几秒），没有 O(1)
# 接口。所以 status 里**不扫盘**，只读上次的统计结果；要新数字显式跑
# `./scripts/dev.sh status --size`（扫完写缓存，status 再读）。
# 缓存里存时间戳：数字有多旧必须能看出来，否则"上个月 118G"会被当成现状。
BUILD_CACHE_WARN_KB=$(( 20 * 1024 * 1024 ))
BUILD_CACHE_FILE="${DEV_DIR}/build-cache"

# 距今多久：秒级时间戳 → "5 分钟前"。用来标注统计结果的时效。
age_label() {
  local then="$1" now diff
  now="$(date +%s)"
  diff=$(( now - then ))
  if (( diff < 0 )); then
    printf '刚刚'
  elif (( diff < 60 )); then
    printf '刚刚'
  elif (( diff < 3600 )); then
    printf '%d 分钟前' $(( diff / 60 ))
  elif (( diff < 86400 )); then
    printf '%d 小时前' $(( diff / 3600 ))
  else
    printf '%d 天前' $(( diff / 86400 ))
  fi
}

# 缓存是否明显过期：目录存在性跟缓存里的数字对不上。
#
# 只做两次 stat（[[ -d ]]），不扫盘。两个方向都要判，否则两种错位都会骗人：
# ① 目录有了但记着 0 —— dev 服务启动会 cargo build，而构建不经过本脚本时缓存
#    不会刷新，没有这一步"刚构建完"会一直显示成"空"。
# ② 目录没了但记着非 0 —— 有人手删了 target 或用别的姿势 cargo clean 过，
#    数字会一直停在旧值。
cache_looks_stale() {
  local deps_kb="$1" incr_kb="$2"
  if [[ -d "${ROOT}/target/debug/deps" ]]; then
    (( deps_kb == 0 )) && return 0
  else
    (( deps_kb > 0 )) && return 0
  fi
  if [[ -d "${ROOT}/target/debug/incremental" ]]; then
    (( incr_kb == 0 )) && return 0
  else
    (( incr_kb > 0 )) && return 0
  fi
  return 1
}

# 红色整行：给两类东西用——会失控增长的数值（构建缓存），以及"要照着抄走"
# 的服务地址。其余行（配置/数据/设备）是中性事实，保持无色，否则一片红等于
# 都没红。与 info/warn 一样不打 TTY 判断——本脚本的输出本来就带转义，
# 混着来会更乱。
red_row() { printf '\033[31m%s\033[0m\n' "$1"; }

# 绿色整行（连前缀符号一起）：正向状态用，目前只有"服务在跑"。
# 留着 › 是为了和 info 打的「数据目录」那行对齐，读者扫一列就知道是同一种行。
ok_row() { printf '\033[32m› %s\033[0m\n' "$1"; }

# 服务地址：本机与局域网两行，整行红。
#
# 为什么值得红：这两行是客户端配对时要手抄的输入，混在一段青色 info 里
# 最容易漏；而填错地址的表现是"客户端连不上"，排查成本远高于一行红色。
#
# 端口由调用方给：启动路径用刚算出来的 port（api.port 可能还没落盘），
# status 路径用 current_port()——两条路径各有各的权威来源，别交叉。
print_service_addresses() {
  local port="$1"
  local scheme host ip

  if [[ -z "${port}" || "${port}" == "unknown" ]]; then
    red_row "  服务地址：未确定（还没启动过，配置里也没有 api_bind）"
    return 0
  fi

  scheme="$(bound_scheme)"
  host="$(bound_host)"

  # 绑具体 IP 时 127.0.0.1 根本连不上，本机行只能照实写。
  case "${host}" in
    ""|0.0.0.0|::|"[::]") red_row "  服务地址：${scheme}://127.0.0.1:${port}" ;;
    *) red_row "  服务地址：${scheme}://${host}:${port}" ;;
  esac

  if is_loopback_bind; then
    # 这里不能照抄一个局域网地址：那是个连不上的地址，只会让人白试一轮。
    red_row "  局域网地址：不可用（仅监听回环；要局域网访问用 AGENT_BIND=0.0.0.0 重启）"
    return 0
  fi

  ip="$(lan_ipv4)"
  if [[ -z "${ip}" ]]; then
    red_row "  局域网地址：未检测到（没有默认路由，检查网络连接）"
    return 0
  fi
  # 直接绑到这张网卡的 IP 时，上一行已经是同一个地址，再打一遍只是噪音。
  if [[ "${host}" == "${ip}" ]]; then
    return 0
  fi
  red_row "  局域网地址：${scheme}://${ip}:${port}"
}

# 真正扫盘的地方，只在这一处。$3 是时间描述，空表示"刚统计"。
print_build_cache_row() {
  local deps_kb="$1" incr_kb="$2" note="${3:-}"
  local total_kb=$(( deps_kb + incr_kb ))
  # 全 0 说明 target/debug 下没有产物：别打一串 0K，直接说"空"。
  # 仍要带时效——否则读者无法判断"空"是刚确认的还是三天前记的。
  if (( total_kb == 0 )); then
    red_row "  构建缓存：空（统计于 ${note:-刚刚}；target/debug 下没有 deps/incremental）"
    return 0
  fi
  local line="  构建缓存：deps $(human_size "${deps_kb}") · incremental $(human_size "${incr_kb}")（合计 $(human_size "${total_kb}")"
  if [[ -n "${note}" ]]; then
    line="${line}，统计于 ${note}"
  fi
  red_row "${line}）"
  if (( total_kb >= BUILD_CACHE_WARN_KB )); then
    warn "构建缓存超过 20G：./scripts/dev.sh clean 可回收（release 产物不动）"
  fi
}

# 扫一次并写缓存。du -skx：统一单位便于累加，-x 不跨文件系统（避免算进挂载点）。
# 目录不存在按 0 记：还没构建过是正常状态。
measure_build_cache() {
  local deps_kb=0 incr_kb=0 size_kb

  if [[ -d "${ROOT}/target/debug/deps" ]]; then
    size_kb="$(du -skx "${ROOT}/target/debug/deps" 2>/dev/null | cut -f1 || true)"
    [[ -n "${size_kb}" ]] && deps_kb="${size_kb}"
  fi
  if [[ -d "${ROOT}/target/debug/incremental" ]]; then
    size_kb="$(du -skx "${ROOT}/target/debug/incremental" 2>/dev/null | cut -f1 || true)"
    [[ -n "${size_kb}" ]] && incr_kb="${size_kb}"
  fi

  mkdir -p "${DEV_DIR}"
  printf '%s %s %s\n' "$(date +%s)" "${deps_kb}" "${incr_kb}" >"${BUILD_CACHE_FILE}"
}

# status 用：只读缓存，不碰文件系统里的产物。
build_cache() {
  local ts=0 deps_kb=0 incr_kb=0

  if [[ ! -f "${BUILD_CACHE_FILE}" ]]; then
    red_row "  构建缓存：未统计（./scripts/dev.sh status --size）"
    return 0
  fi

  # shellcheck disable=SC2034  # ts 只用于下面的 age_label
  read -r ts deps_kb incr_kb <"${BUILD_CACHE_FILE}" || true
  if [[ ! "${ts}" =~ ^[0-9]+$ || ! "${deps_kb}" =~ ^[0-9]+$ || ! "${incr_kb}" =~ ^[0-9]+$ ]]; then
    warn "构建缓存统计文件不可用，重新统计：./scripts/dev.sh status --size"
    return 0
  fi

  # 缓存说 0 但目录已经在了：静默重扫一次，别把刚构建的结果显示成"空"。
  if cache_looks_stale "${deps_kb}" "${incr_kb}"; then
    measure_build_cache
    read -r ts deps_kb incr_kb <"${BUILD_CACHE_FILE}" || true
    [[ "${ts}" =~ ^[0-9]+$ ]] || ts=0
    [[ "${deps_kb}" =~ ^[0-9]+$ ]] || deps_kb=0
    [[ "${incr_kb}" =~ ^[0-9]+$ ]] || incr_kb=0
  fi

  print_build_cache_row "${deps_kb}" "${incr_kb}" "$(age_label "${ts}")"
}

# 显式刷新：这是唯一会扫盘（几秒）的入口。
refresh_build_cache() {
  info "统计构建缓存体积（需遍历 target/debug 下的文件，缓存大时要几秒）"
  measure_build_cache
}

# 当前状态：服务、worker、编码能力、已配对设备，以及配置与库里的数据量。
#
# 取舍：服务没在跑时也要有输出——"为什么连不上"不该只能靠翻日志回答。
# 所以配置摘要与库计数是独立于服务进程取的。
status() {
  local running=0
  if dev_running; then
    running=1
  fi
  local pids
  pids="$(dev_service_pids)"

  info "数据目录：${DATA_DIR}"
  [[ -d "${DATA_DIR}" ]] || warn "数据目录不存在：还没启动过（./scripts/dev.sh）"

  if (( running == 1 )); then
    ok_row "服务：运行中（pid $(printf '%s' "${pids}" | tr '\n' ' ' | sed 's/ *$//')）"
  else
    info "服务：未运行"
    if [[ -n "${pids}" ]]; then
      warn "但仍有进程在（pid $(printf '%s' "${pids}" | tr '\n' ' ')）：可能正在启动或已僵死；必要时 ./scripts/dev.sh stop"
    fi
  fi

  # 地址不看 running：服务停着的时候，恰恰最需要知道"客户端该填什么"。
  # 协议与端口由 bound_scheme()/current_port() 从配置推，不是猜的。
  print_service_addresses "$(current_port)"

  if [[ -f "${CONFIG}" ]]; then
    PA_CONFIG="${CONFIG}" python3 - <<'PY'
import json
import os

with open(os.environ["PA_CONFIG"], encoding="utf-8") as handle:
    config = json.load(handle)

code = config.get("code") or {}
project = config.get("project") or config.get("workspace") or {}
llm = config.get("llm") or {}
asr = config.get("asr") or {}
tts = config.get("tts") or {}
realtime = config.get("realtime") or {}
browser = config.get("browser") or {}
code_state = "on" if code.get("enabled") else "off"
browser_state = (
    f"{len(browser.get('allowed_ports') or [])} 个端口" if browser else "默认白名单"
)
# 读图是"默认关、要显式开"的开关，状态行里必须看得见——否则用户永远在猜
# 自己那句"当前模型未开启读图功能"是配置没生效还是模型不支持。
vision_state = "on" if llm.get("vision") else "off"
parts = [
    "llm=" + ("on" if llm.get("enabled") else "off") + "（vision=" + vision_state + "，"
    + str(llm.get("model") or "服务端默认") + "）",
    "asr=" + ("on" if asr.get("enabled") else "off"),
    "tts=" + ("on" if tts.get("enabled") else "off"),
    "realtime=" + ("on" if realtime.get("enabled") else "off"),
    "code=" + code_state + f"（allow_roots {len(code.get('allow_roots') or [])} 个）",
    f"project.browse_roots {len(project.get('browse_roots') or [])} 个",
    "browser=" + browser_state,
]
print("  配置：api_bind=" + str(config.get("api_bind", "?")) + " · " + " · ".join(parts))
PY
  fi

  if (( running == 1 )); then
    PA_HEALTH="$(admin_get health)" \
      PA_IDENTITY="$(admin_get identity)" \
      PA_WORKER="$(admin_get worker)" \
      PA_CODE="$(admin_get code)" \
      PA_DEVICES="$(admin_get devices)" \
      python3 - <<'PY'
import json
import os


def load(key):
    raw = os.environ.get(key, "").strip()
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


health = load("PA_HEALTH") or {}
identity = load("PA_IDENTITY") or {}
worker = load("PA_WORKER") or {}
code = load("PA_CODE") or {}
devices = load("PA_DEVICES") or []

# 地址在上面由 print_service_addresses 统一以红字打："服务地址/局域网地址"。
# 这里只报版本，避免同一个地址出现两种写法。
print(f"  版本 {health.get('version', '?')}")

tls = identity.get("tls_fingerprint")
line = "  身份指纹 " + str(identity.get("fingerprint", "-"))
print(line + (" · TLS 指纹 " + tls if tls else " · 明文 HTTP"))

skills = worker.get("skills") or []
line = "  worker " + str(worker.get("phase", "unknown"))
if worker.get("pid"):
    line += f"（pid {worker['pid']}）"
if skills:
    line += f" · 技能 {len(skills)} 个：{', '.join(skills)}"
print(line)
if worker.get("last_error"):
    print("  worker 最近错误：" + str(worker["last_error"]))

if code.get("enabled"):
    print(
        "  编码 启用 · "
        + str(code.get("provider"))
        + "/"
        + str(code.get("model"))
        + " · 代理 "
        + str(code.get("proxy") or "-")
        + f" · 活跃任务 {len(code.get('active_tasks') or [])}"
        + f" · 允许根 {code.get('allow_roots', 0)} 个"
        + " · 上游密钥 "
        + ("已配置" if code.get("has_upstream") else "缺失")
    )
else:
    print("  编码 未启用")

active = [device for device in devices if not device.get("revoked_at")]
print(f"  已配对设备 {len(active)} 台")
for device in active[:5]:
    print(
        "    - "
        + str(device.get("name"))
        + "（"
        + str(device.get("platform"))
        + "，id "
        + str(device.get("id"))
        + "）"
    )
PY
  fi

  build_cache
  db_counts
}

# --- 移动客户端（安卓 / iOS） --------------------------------------------------

# 所有 flutter 调用都带这个开关，原因见下（不是洁癖）。
#
# flutter 在「距上次检查超过一天」时会做版本新鲜度检查，内部走
# `git fetch --tags https://github.com/flutter/flutter.git`。这台机器连不上
# github，于是它先**静默**等 TCP 超时（实测 75 秒）才继续——用户看到的现象是
# "敲了命令没反应"，很容易误判成脚本卡死。加 --no-version-check 后命令立刻执行。
FLUTTER_NVC="--no-version-check"

# 列出某个平台的设备，每行 `id<TAB>名称<TAB>平台<TAB>真机/模拟器`。没有则输出空。
#
# 设备来源是 `flutter devices --machine` 而不是 adb / xcrun：Flutter 认的设备才跑得
# 起来（含模拟器与无线设备），底层序列号还得自己映射；SDK 路径也不该写死在本脚本里。
devices_for_platform() {
  local prefix="$1"
  ( cd "${ROOT}/jarvis-app" && flutter "${FLUTTER_NVC}" devices --machine 2>/dev/null ) \
    | python3 -c '
import json
import sys

prefix = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    devices = json.load(sys.stdin)
except ValueError:
    # flutter 输出被截断/不是 JSON 时当"没有设备"，由调用方给可读提示。
    sys.exit(0)

for device in devices:
    # 同一台机器上通常还有 macOS / Chrome / 另一平台的手机，只留目标平台。
    if not str(device.get("targetPlatform", "")).startswith(prefix):
        continue
    print(
        "\t".join(
            [
                str(device.get("id", "")),
                str(device.get("name", "")),
                str(device.get("targetPlatform", "")),
                "模拟器" if device.get("emulator") else "真机",
            ]
        )
    )
' "${prefix}"
}

android_devices() { devices_for_platform android; }
ios_devices() { devices_for_platform ios; }

# 按类型筛设备表：kind 为空表示不限（表里第 4 列就是「真机 / 模拟器」）。
_device_rows() {
  local listing="$1" kind="$2"
  printf '%s\n' "${listing}" \
    | awk -F'\t' -v k="${kind}" 'NF && (k == "" || $4 == k)'
}

# 表里某台设备的类型；查不到输出 unknown。
#
# 查不到就当未知：无线设备、刚启动的模拟器都可能来不及出现在 `flutter devices`
# 里，这时不该拦（类型只影响"要不要强制 debug、注入哪个地址"）。
device_kind() {
  local listing="$1" id="$2"
  printf '%s\n' "${listing}" \
    | awk -F'\t' -v id="${id}" '$1 == id { kind = $4 } END { print (kind == "" ? "unknown" : kind) }'
}

# 选一台安卓设备。多台时不猜：装错机器是这里最贵的一类错误。
#
# $2 为 simulator 时只在模拟器里挑——真机也插着时，默认的"多台不猜"会直接把
# 这条命令拦下来，而模拟器恰恰是最常用的那个目标。
pick_android_device() {
  local listing="$1" want="${2:-auto}"
  local candidate="${listing}"

  if [[ "${want}" == "simulator" ]]; then
    candidate="$(_device_rows "${listing}" "模拟器")"
    if [[ -z "${candidate}" ]]; then
      fail "没有检测到安卓模拟器：
  1. Android Studio → Device Manager 启动一台（或命令行 emulator -avd <name>）
  2. 等 flutter devices 里出现它再重试
  已知设备 id 时也可以直接指定：./scripts/dev.sh client android emulator -d <device-id>"
    fi
  elif [[ -z "${candidate}" ]]; then
    fail "没有检测到安卓设备：
  真机：USB 连上，打开「开发者选项 → USB 调试」，手机上的授权提示点「允许」
        （adb devices 里状态应是 device，不是 unauthorized）
  模拟器：./scripts/dev.sh client android emulator（先启动一台 AVD）
  已知设备 id 时也可以直接指定：./scripts/dev.sh client android -d <device-id>"
  fi

  local count
  count="$(printf '%s\n' "${candidate}" | awk 'NF { n++ } END { print n + 0 }')"

  if (( count > 1 )); then
    # 候选表走 stderr：函数结果是用 $(...) 取的，写 stdout 会被调用方吞掉，
    # 用户就只看到一句"2 台设备"却不知道是哪两台。
    printf '%s\n' "${candidate}" \
      | awk -F'\t' '{ printf "    - %s（%s，%s）\n", $2, $1, $4 }' >&2
    fail "检测到 ${count} 台候选安卓设备，不替你选：
  ./scripts/dev.sh client android -d <device-id>
  只要模拟器：./scripts/dev.sh client android emulator"
  fi

  printf '%s\n' "${candidate}" | awk -F'\t' '{ print $1; exit }'
}

# --- iOS 设备 -----------------------------------------------------------------
#
# 与安卓的差别在于模拟器：iOS 模拟器只支持 debug（见 flutter_tools 的
# ios/simulators.dart，supportsRuntimeMode 只认 debug），连 profile 都会被
# `flutter run` 直接拒绝；真机则 debug/profile/release 都行。
#
# 所以选设备的规则是：
# - 默认（auto）：有真机选真机；没有真机、且只有一台模拟器时就用它，
#   并把模式切成 debug（见 `client_ios`）；
# - `ios simulator` / `ios device` 可以指定只看哪一类；
# - 同类多台一律不猜：装错目标比多敲一次 -d 贵。
#
# 设备表由调用方探测一次后传进来（bash 3.2 没有引用传参，函数里再调 $(...) 探测
# 会落在子 shell，缓存写不回去，白白多等 1~3 秒）。

# 从设备表里挑一台 iOS 设备。$2 是 auto / device / simulator。
pick_ios_device() {
  local listing="$1" want="${2:-auto}"
  local reals sims candidate
  reals="$(_device_rows "${listing}" "真机")"
  sims="$(_device_rows "${listing}" "模拟器")"

  case "${want}" in
    device)
      candidate="${reals}"
      if [[ -z "${candidate}" ]]; then
        fail "没有检测到 iOS 真机：
  1. iPhone 用 USB 连上（本机实测无线调试不可用）
  2. 「设置 → 隐私与安全性 → 开发者模式」打开并重启（只做一次）
  3. 首次装包后若提示未受信任：设置 → 通用 → VPN 与设备管理 里信任一次
  只想用模拟器的话去掉 device：./scripts/dev.sh client ios simulator"
      fi
      ;;
    simulator)
      candidate="${sims}"
      if [[ -z "${candidate}" ]]; then
        fail "没有启动的 iOS 模拟器：
  1. Xcode → Open Developer Tool → Simulator（或 xcrun simctl boot <device-id>）
  2. 等 flutter devices 里能看到它再重试
  已知 id 时也可以直接指定：./scripts/dev.sh client ios simulator -d <simulator-id>"
      fi
      ;;
    *)
      if [[ -n "${reals}" ]]; then
        candidate="${reals}"
      elif [[ -n "${sims}" ]]; then
        candidate="${sims}"
      else
        fail "没有检测到 iOS 设备：
  真机：iPhone 用 USB 连上，打开「开发者模式」并信任本机（只做一次）
  模拟器：Xcode → Open Developer Tool → Simulator
  已知设备 id 时也可以直接指定：./scripts/dev.sh client ios -d <device-id>"
      fi
      ;;
  esac

  local count
  count="$(printf '%s\n' "${candidate}" | awk 'NF { n++ } END { print n + 0 }')"
  if (( count > 1 )); then
    # 候选表走 stderr：函数结果用 $(...) 取，写 stdout 会被调用方吞掉。
    printf '%s\n' "${candidate}" \
      | awk -F'\t' '{ printf "    - %s（%s，%s）\n", $2, $1, $4 }' >&2
    fail "检测到 ${count} 台候选 iOS 设备，不替你选：
  ./scripts/dev.sh client ios -d <device-id>
  只要模拟器：./scripts/dev.sh client ios simulator"
  fi

  printf '%s\n' "${candidate}" | awk -F'\t' '{ print $1; exit }'
}

# `client android [debug|profile|release] [其它 flutter run 参数]`
#
# 默认 release：装的是与打包一致的 AOT 包，启动快、贴近真机体验；代价是
# **没有热重载**（release 下 Flutter 的 r 不可用），改手机端 UI 请显式传 debug。
#
# 不要再补 `adb shell am start`：`flutter run` 本身就是"构建 → 安装 → 启动 → attach"，
# 追加一次启动会和 Flutter 抢着拉起，还丢掉 attach 日志。
client_android() {
  local app_dir="${ROOT}/jarvis-app"
  local mode="release"
  local want="auto"
  local flag_mode=0
  local asked_mode=0
  local arg

  # 目标词与模式都能出现在最前面，顺序随意（`emulator debug` / `debug emulator`）。
  while [[ $# -gt 0 ]]; do
    case "$1" in
      emulator|emu|simulator|sim) want="simulator"; shift ;;
      debug|profile|release) mode="$1"; asked_mode=1; shift ;;
      *) break ;;
    esac
  done

  # 认显式 --debug/--profile/--release：位置参数已经吃过一个模式时再拼 `--${mode}`
  # 会变成两个 mode，flutter 直接报错。显式 flag 优先，也不再补一个。
  for arg in "$@"; do
    case "${arg}" in
      --debug) mode="debug"; flag_mode=1; asked_mode=1 ;;
      --profile) mode="profile"; flag_mode=1; asked_mode=1 ;;
      --release) mode="release"; flag_mode=1; asked_mode=1 ;;
    esac
  done

  # 用户自己给了设备就不再探测：省几秒，也避免"脚本选中 + 命令行又指定"打架。
  local has_device=0
  for arg in "$@"; do
    case "${arg}" in
      -d|--device-id|-d*|--device-id=*) has_device=1 ;;
    esac
  done

  local listing="" device="" kind=""
  if (( has_device == 0 )); then
    info "探测安卓设备…"
    listing="$(android_devices)"
    device="$(pick_android_device "${listing}" "${want}")"
    kind="$(device_kind "${listing}" "${device}")"
  else
    local dev_id
    dev_id="$(device_id_from_args "$@")"
    if [[ -n "${dev_id}" ]]; then
      listing="$(android_devices)"
      kind="$(device_kind "${listing}" "${dev_id}")"
    fi
  fi

  # 表里查不到时按 id 前缀兜底：AVD 的设备 id 恒为 `emulator-<端口>`。
  # 刚启动的模拟器可能还没进 `flutter devices`，这时也该按模拟器对待。
  if [[ "${kind}" == "unknown" && "${device:-}${dev_id:-}" == emulator-* ]]; then
    kind="模拟器"
  fi

  # 模拟器默认 debug：它有热重载，release 只在测性能时显式传。
  if [[ "${kind}" == "模拟器" ]] && (( asked_mode == 0 )) \
    && [[ "${mode}" == "release" ]]; then
    mode="debug"
    info "目标是安卓模拟器：自动切 debug（可热重载）"
  fi

  if (( has_device == 0 )); then
    info "目标设备：${device}（${kind}，${mode}）"
  else
    info "使用命令行指定的设备（${kind}，${mode}）"
  fi

  if [[ "${mode}" != "debug" ]]; then
    info "${mode} 无热重载：改手机端 UI 用 ./scripts/dev.sh client android debug"
  fi

  # 只有 debug 包注入开发参数：release/profile 是 AOT 产物，配对码会被打进包，
  # 包给谁谁就拿到码。
  #
  # 模拟器与宿主是同一台机器：先用 adb reverse 把设备端口映回宿主回环，再按
  # 127.0.0.1 注入——服务只绑回环（默认）也能自动配对。TLS 下回环地址会撞证书
  # SAN，那种情况退回局域网地址（模拟器共享宿主网络，局域网 IP 一样可达）。
  local defines=""
  local port
  port="$(current_port)"
  local sim_loopback=0
  if [[ "${kind}" == "模拟器" && "$(bound_scheme)" == "http" ]]; then
    sim_loopback=1
  fi

  if [[ "${mode}" != "debug" ]] || has_release_flag "$@"; then
    info "非 debug 运行不注入自动配对参数（配对码会被打进产物）"
  elif (( sim_loopback == 1 )); then
    if adb reverse "tcp:${port}" "tcp:${port}" >/dev/null 2>&1; then
      client_dev_defines "http://127.0.0.1:${port}"
    else
      warn "adb reverse 失败，改用 AVD 的宿主回环别名 10.0.2.2"
      client_dev_defines "http://10.0.2.2:${port}"
    fi
    defines="${CLIENT_DEFINES}"
  elif is_loopback_bind; then
    warn "服务只监听回环，手机连不到；本次不注入自动配对参数"
  else
    local lan
    lan="$(lan_ipv4)"
    if [[ -z "${lan}" ]]; then
      warn "没有检测到局域网地址；本次不注入自动配对参数"
    else
      client_dev_defines "$(bound_scheme)://${lan}:${port}"
      defines="${CLIENT_DEFINES}"
    fi
  fi

  local args=(run)
  if [[ -n "${defines}" ]]; then
    args+=("${defines}")
  fi
  # 位置参数给的模式要补成 flag；命令行自己给了 flag 就不再补。
  if (( flag_mode == 0 )); then
    args+=("--${mode}")
  fi
  if [[ -n "${device}" ]]; then
    args+=(-d "${device}")
  fi

  local printable="${args[*]}"
  if (( $# > 0 )); then
    printable="${printable} $*"
  fi

  cd "${app_dir}"
  info "启动客户端：flutter ${printable}"
  exec flutter "${FLUTTER_NVC}" "${args[@]}" "$@"
}

# 从透传参数里取设备 id（`-d <id>` / `-d<id>` / `--device-id <id>` / `--device-id=<id>`）。
# 单独抽出来是因为"判断 -d 的目标是不是模拟器"要拿到具体的值，只判断有没有给不够。
device_id_from_args() {
  local prev="" arg
  for arg in "$@"; do
    if [[ "${prev}" == "-d" || "${prev}" == "--device-id" ]]; then
      printf '%s' "${arg}"
      return 0
    fi
    case "${arg}" in
      -d | --device-id)
        prev="${arg}"
        ;;
      --device-id=*)
        printf '%s' "${arg#--device-id=}"
        return 0
        ;;
      -d*)
        printf '%s' "${arg#-d}"
        return 0
        ;;
    esac
  done
  return 0
}

# `client ios [debug|profile|release] [其它 flutter run 参数]`
#
# 默认 release，与安卓分支一致：AOT 包启动快、贴近真机体验，代价是没有热重载。
#
# 刻意不和 client_android 合并成一个函数：iOS 这边多出模拟器能力差异、构建依赖
# 补位、以及"debug 包不能点图标启动"这类专属提示，合并后两条路径会互相牵制，
# 而安卓那条已经在用、不该为了对称去动它。
client_ios() {
  local app_dir="${ROOT}/jarvis-app"
  local mode="release"
  local want="auto"
  local asked_mode=0

  # 目标词与模式都能出现在最前面，顺序随意（`simulator debug` / `debug simulator`）。
  while [[ $# -gt 0 ]]; do
    case "$1" in
      simulator|sim) want="simulator"; shift ;;
      device|real) want="device"; shift ;;
      debug|profile|release) mode="$1"; asked_mode=1; shift ;;
      *) break ;;
    esac
  done

  # 认显式 --debug/--profile/--release：位置参数已经吃掉一个模式时再拼 `--${mode}`
  # 会变成 `--release --debug` 两个 mode，flutter 直接报错。显式 flag 优先。
  local explicit_mode=0 arg
  for arg in "$@"; do
    case "${arg}" in
      --debug) mode="debug" explicit_mode=1; asked_mode=1 ;;
      --profile) mode="profile" explicit_mode=1; asked_mode=1 ;;
      --release) mode="release" explicit_mode=1; asked_mode=1 ;;
    esac
  done

  local has_device=0
  for arg in "$@"; do
    case "${arg}" in
      -d | --device-id | -d* | --device-id=*) has_device=1 ;;
    esac
  done

  # 设备表只探测一次：选设备要用，判断 -d 的目标是不是模拟器也要用。
  local listing="" device="" kind=""
  if (( has_device == 0 )); then
    info "探测 iOS 设备…"
    listing="$(ios_devices)"
    device="$(pick_ios_device "${listing}" "${want}")"
    kind="$(device_kind "${listing}" "${device}")"
  else
    local dev_id
    dev_id="$(device_id_from_args "$@")"
    if [[ -n "${dev_id}" ]]; then
      listing="$(ios_devices)"
      kind="$(device_kind "${listing}" "${dev_id}")"
    fi
  fi

  # iOS 模拟器只支持 debug（flutter_tools 的 supportsRuntimeMode 只认 debug）：
  # 自动降级，只有用户显式要了别的模式才报错——让 flutter run 抛
  # "Profile mode is not supported..." 时用户还得自己翻译一遍。
  local is_sim=0
  if [[ "${kind}" == "模拟器" ]]; then
    is_sim=1
    if [[ "${mode}" != "debug" ]]; then
      if (( asked_mode == 1 )); then
        fail "iOS 模拟器只支持 debug，${mode} 会被 flutter run 拒绝：
  去掉模式参数即可（模拟器会自动用 debug）：./scripts/dev.sh client ios simulator"
      fi
      mode="debug"
      info "目标是 iOS 模拟器：自动切 debug（可热重载）"
    fi
  fi

  if (( has_device == 0 )); then
    info "目标设备：${device}（${kind}，${mode}）"
  else
    info "使用命令行指定的设备（${kind}，${mode}）"
  fi

  if [[ "${mode}" == "debug" ]]; then
    if (( is_sim == 1 )); then
      info "模拟器上跑的是 debug 包：改代码直接热重载（r），不用管桌面图标。"
    else
      info "debug 包只能由本命令 / IDE 启动：在手机上点图标会提示只能在 Flutter 工具里运行。
  想要脱离电脑从桌面打开，用 ./scripts/dev.sh client ios profile
  首次上机若自动配对提示「包没发出本机」，是 iOS 本地网络权限没真正生效
  （设置里开关显示已开也不算数）：用 profile 装一次、在配对页手动填地址与
  ./scripts/dev.sh pair 生成的码，授权弹窗点允许，之后再切回 debug 即可。"
    fi
  else
    info "${mode} 无热重载：改手机端 UI 用 ./scripts/dev.sh client ios debug"
  fi

  # 只有 debug 包注入开发参数：release/profile 是 AOT 产物，配对码会被打进包，
  # 包给谁谁就拿到码。
  #
  # 模拟器与宿主是同一台机器：http 下走回环就够了（服务只绑 127.0.0.1 也能配对）；
  # 服务是 TLS 时回环地址会撞证书 SAN，改用局域网地址——模拟器共享宿主网络，
  # 局域网 IP 一样可达。真机仍只走局域网。
  local defines=""
  local port
  port="$(current_port)"
  if [[ "${mode}" != "debug" ]] || has_release_flag "$@"; then
    info "非 debug 运行不注入自动配对参数（配对码会被打进产物）"
  elif (( is_sim == 1 )) && [[ "$(bound_scheme)" == "http" ]]; then
    client_dev_defines "$(local_service_url)"
    defines="${CLIENT_DEFINES}"
  elif (( is_sim == 1 )); then
    local sim_lan
    sim_lan="$(lan_ipv4)"
    if [[ -z "${sim_lan}" ]]; then
      warn "服务是 TLS 且没有局域网地址；本次不注入自动配对参数"
    else
      client_dev_defines "https://${sim_lan}:${port}"
      defines="${CLIENT_DEFINES}"
    fi
  elif is_loopback_bind; then
    warn "服务只监听回环，手机连不到；本次不注入自动配对参数"
  else
    local lan
    lan="$(lan_ipv4)"
    if [[ -z "${lan}" ]]; then
      warn "没有检测到局域网地址；本次不注入自动配对参数"
    else
      client_dev_defines "$(bound_scheme)://${lan}:${port}"
      defines="${CLIENT_DEFINES}"
    fi
  fi

  local args=(run)
  if [[ -n "${defines}" ]]; then
    args+=("${defines}")
  fi
  if (( explicit_mode == 0 )); then
    args+=("--${mode}")
  fi
  if [[ -n "${device}" ]]; then
    args+=(-d "${device}")
  fi

  local printable="${args[*]}"
  if (( $# > 0 )); then
    printable="${printable} $*"
  fi

  cd "${app_dir}"
  info "启动客户端：flutter ${printable}"
  exec flutter "${FLUTTER_NVC}" "${args[@]}" "$@"
}

# 启动 Flutter 客户端。额外参数原样传给 `flutter run`（例如 -d chrome / -d <设备 id>）。
client() {
  command -v flutter >/dev/null 2>&1 || fail "未找到 flutter：装好 Flutter SDK 并加进 PATH 再试"
  local app_dir="${ROOT}/jarvis-app"
  [[ -d "${app_dir}" ]] || fail "找不到客户端工程：${app_dir}"

  if dev_running; then
    # 手机端要填局域网那一行，所以两行都打：只给 127.0.0.1 会让它在手机上白试一轮。
    print_service_addresses "$(current_port)"
  else
    # 不是错误：客户端可以先开着等，连不上会在界面上提示。
    # 但先说一句，否则第一眼看到的"连不上服务"像是客户端坏了。
    warn "dev 服务没在运行：客户端启动后会连不上；另开终端跑 ./scripts/dev.sh"
  fi

  # 只拦截首参 `android` / `ios`：其余参数仍原样透传给 flutter run，回归风险最小。
  case "${1:-}" in
    android)
      shift
      client_android "$@"
      return
      ;;
    ios)
      shift
      client_ios "$@"
      return
      ;;
  esac

  # bash 3.2（macOS 自带）在 `set -u` 下对空 `"$@"` 会报 unbound variable，
  # 所以先判空再赋值——`local extra=("$@")` 在无参数时会直接把脚本打死。
  local extra=()
  if (( $# > 0 )); then
    extra=("$@")
  fi

  # 桌面端注入开发参数：release 运行不注入（配对码会随产物分发）。
  #
  # `${extra[@]+"${extra[@]}"}`：bash 3.2 在 `set -u` 下展开**空数组**会报
  # unbound variable（4.4 才修），只有这个写法在两种情况下都安全。
  local defines=""
  if has_release_flag ${extra[@]+"${extra[@]}"}; then
    info "release 运行不注入自动配对参数（配对码会被打进产物）"
  else
    client_dev_defines "$(local_service_url)"
    defines="${CLIENT_DEFINES}"
  fi

  local args=(run)
  if [[ -n "${defines}" ]]; then
    args+=("${defines}")
  fi

  cd "${app_dir}"

  if (( ${#extra[@]} > 0 )); then
    info "启动客户端：flutter run ${extra[*]}"
    exec flutter "${FLUTTER_NVC}" "${args[@]}" "${extra[@]}"
  fi

  local target=""
  case "$(uname -s)" in
    Darwin) target="macos" ;;
    Linux) target="linux" ;;
  esac

  if [[ -n "${target}" ]]; then
    info "启动客户端：flutter run -d ${target}"
    exec flutter "${FLUTTER_NVC}" "${args[@]}" -d "${target}"
  fi

  info "启动客户端：flutter run"
  exec flutter "${FLUTTER_NVC}" "${args[@]}"
}

serve() {
  if dev_running; then
    # 同一个数据目录起第二个实例会被 daemon-kit 以 pid 冲突拒绝，
    # 且端口扫描会误判成"被别的程序占用"而错换端口。这里直接说清楚。
    fail "dev 服务已在运行（${DATA_DIR}）。
  生成配对码：./scripts/dev.sh pair
  停掉它：  ./scripts/dev.sh stop
  重新开始：./scripts/dev.sh stop && ./scripts/dev.sh reset（清空数据）"
  fi

  local port
  port="$(pick_port)"
  write_config "${port}"

  info "构建 workspace（worker 必须与 service 同级）"
  cargo build --workspace
  # 构建刚结束，顺手把体积统计刷新：这样 status 不用再手动 --size，
  # 也不会出现"刚编译完却显示空"的错位。
  measure_build_cache

  print_next_steps "${port}"

  if [[ ! -x "${SERVICE_BIN}" ]]; then
    fail "未找到 ${SERVICE_BIN}，先跑一次 cargo build --workspace"
  fi

  # 没有热更新这回事：改代码只能重启进程。数据目录独立，
  # 所以重启不会毁掉已配对设备与历史（挑战表在内存里，重新登录即可）。
  if command -v cargo-watch >/dev/null 2>&1; then
    info "cargo-watch 已安装：改 crates/ 下的代码会自动重启"
    exec cargo watch -w "${ROOT}/crates" -w "${ROOT}/Cargo.toml" \
      -s "cargo build --workspace && exec cargo run -q -p jarvis-service -- --foreground --config '${CONFIG}'"
  fi

  info "未安装 cargo-watch，本次为手动重启（cargo install cargo-watch 可获得自动重启）"
  exec cargo run -q -p jarvis-service -- --foreground --config "${CONFIG}"
}

pair() {
  [[ -f "${CONFIG}" ]] || fail "还没有 dev 配置，先运行一次 ./scripts/dev.sh"
  local socket="${DATA_DIR}/admin.sock"
  if [[ ! -S "${socket}" ]]; then
    fail "服务未在运行（找不到 ${socket}）；先在另一个终端跑 ./scripts/dev.sh"
  fi

  # `pair reset` 是顺手写法，CLI 侧是 long flag（与 --list/--approve 一致）：
  # 在这里归一化，两种写法都落到同一个 `--reset`，不会长出第二套语义。
  if [[ "${1:-}" == "reset" ]]; then
    shift
    set -- --reset "$@"
  fi

  local binary="${SERVICE_BIN}"
  [[ -x "${binary}" ]] || binary="cargo"
  if [[ "${binary}" == "cargo" ]]; then
    cargo run -q -p jarvis-service -- --config "${CONFIG}" pair "$@"
  else
    "${binary}" --config "${CONFIG}" pair "$@"
  fi
}

# 技能包管理：透传给 `jarvis-service plugin`。
#
# 不需要服务在跑——装包就是"落盘 + 改库"，服务在跑时会自己重载执行进程，
# 没在跑则下次启动生效。dev 的数据目录与 release 是两个，所以必须带 --config，
# 否则会装到 ~/.local/share 那一份去。
plugin() {
  [[ -f "${CONFIG}" ]] || fail "还没有 dev 配置，先运行一次 ./scripts/dev.sh"

  local binary="${SERVICE_BIN}"
  [[ -x "${binary}" ]] || binary="cargo"
  if [[ "${binary}" == "cargo" ]]; then
    cargo run -q -p jarvis-service -- --config "${CONFIG}" plugin "$@"
  else
    "${binary}" --config "${CONFIG}" plugin "$@"
  fi
}

reset() {
  # 服务还活着时删数据目录，等于对着打开的文件删 inode：进程继续写，
  # 下次启动看到的是半套数据。所以先把实例收掉再清。
  if [[ -n "$(dev_service_pids)" ]]; then
    info "reset 之前先停止正在运行的 dev 服务"
    stop
  fi
  if [[ ! -d "${DATA_DIR}" ]]; then
    info "没有可清理的数据（${DATA_DIR} 不存在）"
    return
  fi
  rm -rf "${DATA_DIR}"
  info "已删除 ${DATA_DIR}：下次启动等于全新安装（配对、会话、产物都清空）"
}

# 清理 dev 构建缓存。
#
# target/debug/deps 与 target/debug/incremental 会各自涨到几十上百 GB：
# crates/jarvis-service/tests 下每个 *.rs 都是独立 crate，各自把整棵依赖树静态链一遍，
# 每个目标文件又都带调试信息。所以给一个固定入口，别让人手敲 rm -rf。两条要点：
# ① 走 cargo clean --profile dev，不手动删子目录——cargo 会连同 .fingerprint 与顶层
#    lib*.rlib 一起收掉；只删 deps/ 或 incremental/ 会留下不一致的指纹，后续构建报
#    "产物找不到"这类难查的错。
# ② 先停服务：cargo-watch 还活着的话，清完立刻被重新构建回去，等于白清。
# release 产物不动——那是打包用的，重编代价和收益都不划算。
clean() {
  if [[ -n "$(dev_service_pids)" || -n "$(dev_watcher_pids)" ]]; then
    info "clean 之前先停止正在运行的 dev 服务（否则 cargo-watch 会立刻重建）"
    stop
  fi

  info "清理 dev 构建产物：cargo clean --profile dev（target/debug，含 deps 与 incremental）"
  ( cd "${ROOT}" && cargo clean --profile dev )

  # 清完这两个目录必然为空，直接把缓存写成 0：省一次扫盘，也免得 status 还显示旧数值。
  measure_build_cache
  info "下次构建是全量重编；只做类型检查可用 cargo check / cargo clippy"
}

case "${1:-serve}" in
  serve | start)
    shift || true
    serve
    ;;
  pair)
    shift
    pair "$@"
    ;;
  plugin)
    shift
    plugin "$@"
    ;;
  status)
    shift || true
    case "${1:-}" in
      # 只有显式要求才扫盘：遍历 target/debug 要几秒，日常 status 不该背这个代价。
      --size) refresh_build_cache ;;
      "") ;;
      *) fail "status 只接受 --size（重新统计构建缓存体积），收到：$1" ;;
    esac
    status
    ;;
  client)
    shift
    client "$@"
    ;;
  stop)
    stop
    ;;
  restart)
    restart
    ;;
  reset)
    reset
    ;;
  clean)
    clean
    ;;
  -h | --help | help)
    print_help
    ;;
  *)
    fail "未知子命令：$1（可用：serve / status / client / pair / stop / restart / reset / clean / help）"
    ;;
esac
