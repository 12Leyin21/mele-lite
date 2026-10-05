#!/usr/bin/env bash
# Mele Host 一条命令安装（10-04）。在一台干净的 Ubuntu / Debian 服务器上用 root 跑：
#   curl -fsSL https://raw.githubusercontent.com/12Leyin21/mele-lite/main/host/install.sh | bash
# 可选：MELE_DOMAIN=你的域名（先把域名解析到这台服务器）；不填就用 sslip.io。
set -euo pipefail

DIR=/opt/mele-host
RAW=${MELE_RAW:-https://raw.githubusercontent.com/12Leyin21/mele-lite/main/host}

say() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "请用 root 跑（或者 sudo bash）"
[ "$(uname -s)" = Linux ] || die "只支持 Linux 服务器"

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem_mb" -ge 3500 ] || die "内存只有 ${mem_mb}MB，Mele Host 至少要 4GB（记忆模型要 2～3GB）"

# 4GB 的机器上记忆模型一加载就吃掉一半（10-04 实测峰值约 2GB）；没有交换区的话加 2GB 兜底，免得内存一紧进程被杀
if [ "$mem_mb" -lt 6000 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ] && [ ! -f /swapfile ]; then
  say "加 2GB 交换区（内存小于 6GB）"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if ! command -v docker >/dev/null 2>&1; then
  say "安装 Docker"
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null 2>&1 || die "装好了 Docker 但没有 docker compose 插件"
command -v qrencode >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq qrencode >/dev/null || true; }

mkdir -p "$DIR" && cd "$DIR"
say "下载配置"
for f in docker-compose.yml Caddyfile mele-host; do curl -fsSL "$RAW/$f" -o "$f"; done
install -m 755 mele-host /usr/local/bin/mele-host

if [ ! -f .env ]; then
  ip=$(curl -fsS4 https://api.ipify.org || true)
  if [ -z "${MELE_DOMAIN:-}" ]; then
    [ -n "$ip" ] || die "拿不到公网 IP，请用 MELE_DOMAIN=你的域名 再跑一次"
    MELE_DOMAIN="${ip//./-}.sslip.io"
  fi
  rand() { openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '\n'; }
  cat > .env <<ENV
MELE_DOMAIN=$MELE_DOMAIN
MASTER_KEY=$(rand 32)
SECRET=$(rand 48)
DB_PASSWORD=$(openssl rand -hex 24)
RERANK=0
ENV
  chmod 600 .env
fi
set -a; . ./.env; set +a

say "启动（第一次要下载镜像，几分钟）"
docker compose pull --ignore-pull-failures
docker compose up -d

say "下载记忆模型（约 2.3GB，只这一次）"
docker compose exec -T mele python -m api.host warm

say "等 HTTPS 证书"
for _ in $(seq 1 60); do
  curl -fsS "https://$MELE_DOMAIN/version" >/dev/null 2>&1 && break
  sleep 5
done
curl -fsS "https://$MELE_DOMAIN/version" >/dev/null || die "https://$MELE_DOMAIN 连不上：检查防火墙 80 / 443 端口有没有开"

mele-host pair

cat <<DONE

✅ 装好了：https://$MELE_DOMAIN

⚠️  主密钥（加密你存在服务器上的模型 key，丢了就全解不开）——现在就抄一份放安全的地方：
    $MASTER_KEY
    以后随时看：mele-host key

常用：mele-host pair（重新配对）· mele-host update（升级）· mele-host logs（看日志）
DONE
