# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 装之前要准备（如先配出口代理）：写 before_install。

web_assert() { grep -qi 'homebox-frontend'; }   # 首页是 SPA 外壳，内嵌配置里有 homebox-frontend

# 走应用专用的 OIDC 端点换会话（浏览器里 SPA 自动跳转走的就是它），identity_check 和两个数据钩子共用。
_homebox_login() {
  curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' "$SMOKE_WEB_URL/api/v1/users/login/oidc" >/dev/null ||
    { echo "OIDC 登录链失败"; return 1; }
}

identity_check() { # 走应用专用的 OIDC 端点换会话，再调它自己的“当前用户”接口
  local me
  _homebox_login || return 1
  me="$(web_get /api/v1/users/self -H 'Accept: application/json')" || { echo "/api/v1/users/self 失败：$me"; return 1; }
  # OIDC 建的账号：oidcIssuer 非空；邮箱是主人的。
  jq -e --arg u "$SMOKE_OWNER" \
    '.item.oidcIssuer != null and .item.isSuperuser == false and (.item.email | startswith($u + "@"))' \
    <<<"$me" >/dev/null ||
    { echo "当前用户不是主人的 OIDC 账号：$me"; return 1; }
}

# 数据：建一个名字带随机标记的条目（落 Homebox 的 SQLite，升级后还在）。上游 v0.27 的 entity merge
# 之后条目是“实体”：先取非位置的类型（上游至少内置 Item），再 POST /api/v1/entities。
data_write() {
  local marker types type_id resp id
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  _homebox_login || return 1
  types="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Accept: application/json' \
    "$SMOKE_WEB_URL/api/v1/entity-types")" || { echo "读实体类型失败：$types"; return 1; }
  # 上游 OpenAPI：GET /api/v1/entity-types 返回 EntityTypeSummary 的裸数组（实测 v0.27.1 如此），
  # .items? 兼容带 items 包装的历史形状；// 不吞错误，必须用 ? 压掉对数组的错误索引。
  type_id="$(jq -er '(.items? // .) | [.[]? | select(.isLocation != true)][0].id // empty' <<<"$types")" ||
    { echo "没有可用的条目类型：$types"; return 1; }
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d '{"name":"'"$marker"'","entityTypeId":"'"$type_id"'"}' "$SMOKE_WEB_URL/api/v1/entities")" ||
    { echo "建条目失败：$resp"; return 1; }
  id="$(jq -er '.item.id // .id // empty' <<<"$resp")" || { echo "建条目响应里没有 id：$resp"; return 1; }
  jq -nc --arg id "$id" --arg marker "$marker" '{id:$id,marker:$marker}' >"$SMOKE_STATE"
}

data_check() {
  local state id marker resp code body seen
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  state="$(cat "$SMOKE_STATE")" || { echo "读不到 $SMOKE_STATE"; return 1; }
  id="$(jq -r '.id' <<<"$state")"
  marker="$(jq -r '.marker' <<<"$state")"
  _homebox_login || return 1
  resp="$(curl -sS --noproxy '*' -w $'\n%{http_code}' -b "$SMOKE_JAR" -H 'Accept: application/json' \
    "$SMOKE_WEB_URL/api/v1/entities/$id")"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  [[ "$code" == 200 ]] || { echo "条目 $id 读不到（HTTP $code）：$(head -c 200 <<<"$body")"; return 1; }
  seen="$(jq -r '.item.name // .name // empty' <<<"$body")"
  [[ "$seen" == "$marker" ]] || { echo "条目名对不上：写了 $marker，读到 $seen（$(head -c 200 <<<"$body")）"; return 1; }
}

# ---------- 内部邮箱（notify）的端到端检查 ----------

_mp_api() { # <路径>：调 Mailpit 的 HTTP API（basic core:<api-password>）。Mailpit 只挂在插件网络，
  # 宿主够不着；照核心自己 smoke-mailbox 的做法，在核心容器的网络栈里起一次性 curl 访问它。
  local core pw dd out
  core="wonton-${SMOKE_INSTANCE:?}--core"
  docker inspect "$core" >/dev/null 2>&1 || { echo "找不到核心容器 $core"; return 1; }
  if declare -F read_env >/dev/null; then dd="$(read_env WONTON_DATA_DIR)"
  elif declare -F probes_setting >/dev/null; then dd="$(probes_setting WONTON_DATA_DIR)"
  else echo "读不到 WONTON_DATA_DIR（read_env / probes_setting 都没有）"; return 1; fi
  pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
  [[ -n "$pw" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
  out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
    -s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
  if [[ "$out" == "{"* ]]; then printf '%s' "$out"; return 0; fi
  echo "Mailpit 没给出 JSON：$(head -c 200 <<<"$out")"
  return 1
}

_mp_wait() { # <jq 过滤> [轮数=20]：轮询 Mailpit 信箱直到过滤命中
  local filt="$1" n="${2:-20}" i out
  for ((i = 0; i < n; i++)); do
    out="$(_mp_api "/api/v1/messages?limit=100")" || { sleep 3; continue; }
    jq -e "$filt" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

_owner_email() { # 主人资料里的内部邮箱（收件人用它，不猜域名）
  local base token me
  base="${E2E_BASE:-${SMOKE_BASE:-}}"; token="${E2E_TOKEN:-${SMOKE_TOKEN:-}}"
  [[ -n "$base" && -n "$token" ]] || { echo "没有核心地址或主人令牌"; return 1; }
  me="$(curl -sS --noproxy '*' --fail-with-body -H "Authorization: Bearer $token" "$base/_wonton/api/me")" ||
    { echo "读不到主人资料（/_wonton/api/me）"; return 1; }
  jq -er '.email // empty' <<<"$me" || { echo "主人资料里没有邮箱：$me"; return 1; }
}

extra_check() { # 内部邮箱端到端：README 文档的 Shoutrrr URL 能真发信，测试信进 Mailpit、核心投进主人私聊后删掉
  local to rc
  to="$(_owner_email)" || { echo "$to"; return 1; }
  _homebox_login || return 1

  # README「应用发的信」一节的地址模板原样发一封测试信（应用自己的 /notifiers/test，204 = 发出）；
  # 不先建 notifier：这条接口直接按 URL 发，不用事后清理
  rc="$(web_get /api/v1/notifiers/test -X POST -H 'Content-Type: application/json' \
    --data "{\"url\":\"smtp://smtp.wonton.internal:25/?from=software.homebox@plugins.wonton.internal&to=$to&usestarttls=No\"}" \
    -o /dev/null -w '%{http_code}')" || { echo "notifiers/test 请求失败"; return 1; }
  [[ "$rc" == 204 || "$rc" == 200 ]] ||
    { echo "测试通知没发出去（HTTP $rc）：smtp.wonton.internal:25 连不上或地址被拒"; return 1; }
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mp_wait --arg to "$to" '.messages | any(.To[].Address == $to)' ||
    { echo "60 秒内没在内部邮箱看到收件人 $to 的 homebox 测试信"; return 1; }
  echo "homebox 测试信已进内部邮箱（收件人 $to）"
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mp_wait --arg to "$to" '(.messages | map(select(.To[].Address == $to)) | length) == 0' ||
    { echo "信一直留在 Mailpit：核心没把它投进收件人的 Wonton 私聊（投完才会删）"; return 1; }
  echo "核心已把 homebox 测试信投进 $to 的 Wonton 私聊"
}
