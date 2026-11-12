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

# 先经开发套件建核心会话（主人令牌换网关会话），再走应用专用的 OIDC 端点换应用会话（浏览器里 SPA
# 自动跳转走的就是它）。应用 API 都在网关后面，没有核心会话直接 401（"Sign in to Wonton first"）。
# OIDC 链只在申请了 sso 的新版本上通；tag（无 sso）没有 OIDC 客户端，走不通就算了——
# 网关会话已建好，网关对应用网页按会话自动登录，数据钩子照常能用。
_homebox_login() {
  dweb / -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' >/dev/null ||
    { echo "核心会话建立失败"; return 1; }
  dweb /api/v1/users/login/oidc -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' >/dev/null || true
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
  dd="$(docker exec "$core" printenv WONTON_DATA_DIR 2>/dev/null)"
  [[ -n "$dd" ]] || { echo "核心容器没有 WONTON_DATA_DIR"; return 1; }
  pw="$(docker exec "$core" cat "$dd/core/mailpit/api-password" 2>/dev/null)"
  [[ -n "$pw" ]] || { echo "读不到 Mailpit API 密码（核心数据目录 core/mailpit/api-password）"; return 1; }
  out="$(docker run --rm --network "container:$core" curlimages/curl:8.23.0 \
    -s -u "core:$pw" "http://mailpit.wonton.internal:8025$1" 2>&1)"
  if [[ "$out" == "{"* ]]; then printf '%s' "$out"; return 0; fi
  echo "Mailpit 没给出 JSON：$(head -c 200 <<<"$out")"
  return 1
}

_mp_wait() { # <jq 参数…> [轮数=20]：轮询 Mailpit 信箱直到过滤命中。参数原样交给 jq（--arg 键 值、过滤串）；
  # 最后一个参数是纯数字时取作轮数。
  local -a args=()
  local n=20 a i out
  while (($#)); do
    a="$1"; shift
    if (($# == 0)) && [[ "$a" =~ ^[0-9]+$ ]]; then n="$a"; else args+=("$a"); fi
  done
  ((${#args[@]})) || { echo "mp_wait 没给 jq 过滤"; return 1; }
  for ((i = 0; i < n; i++)); do
    out="$(_mp_api "/api/v1/messages?limit=100")" || { sleep 3; continue; }
    jq -e "${args[@]}" <<<"$out" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

# 核心把信投进主人的私聊后马上从内部邮箱删掉（投完才删），等“信出现在 Mailpit”有竞态：
# 直接断言投递的结果——以主人身份读主人的 Wonton 私聊（通知房间），找这个插件发的信。

_mx_curl() { # <路径> [curl 参数…]：在核心容器的网络栈里调 Tuwunel 的 Matrix 客户端接口（宿主够不着）
  local path="$1"; shift
  docker run --rm --network "container:wonton-${SMOKE_INSTANCE:?}--core" curlimages/curl:8.23.0 \
    -sS --noproxy '*' --max-time 30 --fail-with-body "$@" "http://tuwunel.wonton.internal:8008$path"
}

_mx_room_mail() { # <插件 id>：以主人身份读主人的 Wonton 私聊，输出这个插件发进来的信（结构化事件数组）
  local core="wonton-${SMOKE_INSTANCE:?}--core" admin server room owner tok enc
  admin="$(docker exec "$core" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-admin-token"')" ||
    { echo "拿不到核心的 Matrix 管理令牌"; return 1; }
  server="$(docker exec "$core" sh -c 'cat "$WONTON_MATRIX_SERVER_NAME_FILE" 2>/dev/null || printf %s "${WONTON_MATRIX_SERVER_NAME:-}"')"
  [[ -n "$server" ]] || { server="${SMOKE_BASE#*://}"; server="${server%%:*}"; }
  room="$(docker exec "$core" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-notice-room" 2>/dev/null')" ||
    { echo "主人的通知房间还没建（还没投过信？）"; return 1; }
  enc="$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$room")"
  owner="@${SMOKE_OWNER:-owner}:$server"
  tok="$(_mx_curl "/_synapse/admin/v1/users/$owner/login" \
    -H "Authorization: Bearer $admin" -H 'Content-Type: application/json' -d '{}' | jq -er '.access_token // empty')" ||
    { echo "换不出主人的 Matrix 会话（impersonate 失败）"; return 1; }
  _mx_curl "/_matrix/client/v3/rooms/$enc/messages?dir=b&limit=30" -H "Authorization: Bearer $tok" |
    jq -c --arg id "$1" '[.chunk[] | select(.content["app.wonton.plugin_mail"].plugin_id == $id)]'
}

_mx_wait_mail() { # <插件 id> [轮数=30]：轮询主人的私聊，等这封信出现在房间里（每轮 2 秒）
  local id="$1" n="${2:-30}" i chunk
  for ((i = 0; i < n; i++)); do
    chunk="$(_mx_room_mail "$id")" || { sleep 2; continue; }
    [[ "$chunk" != "[]" ]] && { printf '%s' "$chunk"; return 0; }
    sleep 2
  done
  return 1
}

extra_check() { # 内部邮箱端到端：README 文档的 Shoutrrr URL 能真发信，测试信进 Mailpit、核心投进主人私聊后删掉
  local init_mail to rc
  init_mail="wonton-${SMOKE_INSTANCE:?}--software-homebox--init-mail"
  # 收件人用 init 注入的内部邮箱（MP_SMTP_ALLOWED_RECIPIENTS 只放行 <用户名>@wonton.internal）；
  # /_wonton/api/me 的邮箱在开发栈是实例域形态（fill_profile 写的），会被 550 拒收。
  # WONTON_OWNER_EMAIL 只在 init-mail 的环境里（compose 只给它配了），容器已退出，用 inspect 读。
  to="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$init_mail" 2>/dev/null |
    sed -n 's/^WONTON_OWNER_EMAIL=//p')" ||
    { echo "init-mail 容器里读不到 WONTON_OWNER_EMAIL（容器 $init_mail）"; return 1; }
  [[ -n "$to" ]] || { echo "WONTON_OWNER_EMAIL 是空"; return 1; }
  _homebox_login || return 1

  # README「应用发的信」一节的地址模板原样发一封测试信（应用自己的 /notifiers/test，200/204 = 发出）；
  # 不先建 notifier：这条接口直接按 URL 发，不用事后清理。v0.27.1 的契约是 JSON body 里的 url 字段
  # （demo 站 swagger 是新版才改成查询参数）；URL 不带用户名密码时 Shoutrrr 免认证明文直连。
  resp="$(web_get /api/v1/notifiers/test -X POST -H 'Content-Type: application/json' \
    --data '{"url":"smtp://smtp.wonton.internal:25/?fromAddress=software.homebox@plugins.wonton.internal&toAddresses='"$to"'"}' \
    -w $'\n%{http_code}')" || { echo "notifiers/test 请求失败：$resp"; return 1; }
  rc="${resp##*$'\n'}"
  [[ "$rc" == 204 || "$rc" == 200 ]] ||
    { echo "测试通知没发出去（HTTP $rc）：${resp%$'\n'*}"; return 1; }
  # shellcheck disable=SC2016  # jq 程序，不能让 bash 展开
  _mx_wait_mail software.homebox ||
    { echo "60 秒内没在主人的 Wonton 私聊看到 homebox 的测试信（收件人 $to）"; return 1; }
  echo "homebox 测试信已投进 $to 的 Wonton 私聊"
}
