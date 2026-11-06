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

identity_check() { # 走应用专用的 OIDC 端点换会话，再调它自己的“当前用户”接口
  local final me
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' "$SMOKE_WEB_URL/api/v1/users/login/oidc")" ||
    { echo "OIDC 登录链失败：$final"; return 1; }
  me="$(web_get /api/v1/users/self -H 'Accept: application/json')" || { echo "/api/v1/users/self 失败：$me"; return 1; }
  # OIDC 建的账号：oidcIssuer 非空；邮箱是主人的。
  jq -e --arg u "$SMOKE_OWNER" \
    '.item.oidcIssuer != null and .item.isSuperuser == false and (.item.email | startswith($u + "@"))' \
    <<<"$me" >/dev/null ||
    { echo "当前用户不是主人的 OIDC 账号：$me"; return 1; }
}
