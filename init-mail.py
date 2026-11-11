"""一次性初始化：把应用里账号的邮箱同步成注入的内部邮箱（WONTON_OWNER_EMAIL）。

homebox 的 OIDC 登录按 issuer+sub 认既有账号，命中后不再更新 email 字段（上游
service_user.go 的 LoginOIDC 只在新建账号时写邮箱），所以核心换成内部邮箱后，装好的实例
要改一次。幂等：已是目标值就不动；数据库还没建（首次安装）就什么都不做。脚本以主人的
用户身份运行，SQLite 的 -wal/-shm 也归它。
"""

import os
import sqlite3
import sys

# 上游镜像的 HBOX_DATABASE_SQLITE_PATH 默认指向 /data/homebox.db（见其 Dockerfile），
# python 初始化容器里没有这个变量，按固定路径读。
DB_PATH = "/data/homebox.db"


def die(message):
    print(f"init-mail: {message}", file=sys.stderr)
    sys.exit(1)


def main():
    target = os.environ.get("WONTON_OWNER_EMAIL", "").strip()
    if not target:
        die("WONTON_OWNER_EMAIL is not set; the manifest must request owner.identity")

    if not os.path.exists(DB_PATH):
        # 首次安装时 homebox 还没建库；首个账号由 OIDC 登录创建，邮箱直接取声明里的新地址。
        print("init-mail: no database yet, nothing to do")
        return

    db = sqlite3.connect(DB_PATH, timeout=10)
    try:
        rows = db.execute("SELECT id, email FROM users").fetchall()
        if not rows:
            print("init-mail: no accounts yet, nothing to do")
            return
        if len(rows) > 1:
            # 插件关了注册和本地登录，正常只有一个账号；出现多个时认不出哪个是主人的，
            # 只认唯一的超级用户，认不出就失败退出，不猜。
            superusers = db.execute("SELECT id, email FROM users WHERE is_superuser = 1").fetchall()
            if len(superusers) != 1:
                die(
                    f"expected one account, found {len(rows)} and no single superuser;"
                    " update the email in the app manually"
                )
            rows = superusers
        user_id, email = rows[0]
        if email == target:
            print("init-mail: account email already up to date")
            return
        db.execute("UPDATE users SET email = ? WHERE id = ?", (target, user_id))
        db.commit()
        print(f"init-mail: account email updated ({email} -> {target})")
    except sqlite3.Error as err:
        die(f"database error: {err}")
    finally:
        db.close()


main()
