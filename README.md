# 云吞插件：HomeBox

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

HomeBox（[homebox.software](https://homebox.software)，AGPL-3.0-only）是自托管的家庭物品清单：把家里的东西登记成
清单，记下放在哪个位置、拍了什么照片、值多少钱；位置和物品都编上资产号、能打印二维码标签，扫码就能找到。这个插件把它
装进云吞：网页经核心网关打开，登录走核心的身份提供方，打开直接进入你自己的清单，没有第二个登录页。

插件用上游官方镜像 `docker.io/sysadminsmedia/homebox`（ghcr 上游不发布版本标签），按版本标签加摘要固定。清单、附件和缩略图都在插件自己的数据目录里，
不要额外的数据库和缓存。

## 应用发的信

Homebox 自己会发信的功能是保养到期提醒：在应用里「通知（Notifiers）」加一条 SMTP 通知，地址填
`smtp://smtp.wonton.internal:25/?from=software.homebox@plugins.wonton.internal&to=<你的用户名>@wonton.internal&usestarttls=No`（不填用户名密码）。
信会出现在你的 Wonton 私聊里；收件人只能写家里人的地址，发给外面地址会被服务器当场拒收，测试通知报失败。

登录只走云吞的身份，账号没有密码，所以「忘记密码」的邮件流程用不上；忘了密码就在应用里重新登录一次。

## 图标来源与许可

`icon.svg` 取自 HomeBox 的官方标志（frontend/public/favicon.svg），未改颜色和比例，按插件规范补成正方形画布、等比
居中放在白色底上，未用图片模型生成；来源、版权、处理方式、上游 AGPL-3.0 全文和商标说明见 [NOTICE](NOTICE)。

该标志为 HomeBox 项目及其权利人的商标，仅用于识别本插件所集成的应用；本插件不代表 HomeBox 官方，
也不表示获得 HomeBox 的合作、认可或背书。

## 先跑起来
## 核心升级

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。

## 先跑起来

```bash
scripts/dev.sh up
```

```bash
scripts/dev.sh install
```

`up` 在本机起一套云吞，打印它的地址。示例（实例名取自目录名加 4 位随机数，端口随机）是
`http://homebox3f2a.wonton.localhost:21234/`。浏览器打开，用 `scripts/dev.sh token` 输出的用户令牌登录。`install` 先列出
插件要的权限，确认后装上，打印插件网页的地址。Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.svg` | 清单引用的文件：图标 |
| `screenshots/` | 商店详情页里的截图 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：打 tag、推送；`images/` 里有自己构建的镜像时先构建、推送并按摘要写回（示例没有） |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE` | 插件包自己的许可证；从模板新建时换成作者自己的名字和年份 |
| `NOTICE` | 图标等第三方素材的许可和声明；图标是自己画的就写原创和插件许可证，见[插件规范](https://github.com/wontonapp/wonton-docs/blob/main/plugin-spec.md) |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |

插件包是 `docker-compose.yml` 加上它引用的文件：`icon`、`settings`、`bot.avatar`、`notices` 和顶层 `configs` 的 `file`。README、
截图、Dockerfile、源码都不在插件包里，核心不取。引用的路径相对仓库根目录，不能是绝对路径、不能含 `..`、不能用变量，
也不能经过软链接；单个文件不超过 1 MiB，整个插件包不超过 2 MiB。安装时插件包以 tar 归档上传，归档里只能有普通文件和
目录，最多 256 项。

