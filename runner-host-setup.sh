#!/usr/bin/env bash
# GitHub Actions self-hosted runner ホストのセットアップ（Linux + systemd / apt 系）
#
# ジョブ実行の前提（パスワード不要 sudo / Docker / Buildx / docker グループ / C コンパイラ）を
# 整え、登録済み runner を systemd サービスとして起動する。
#
# 前提: config.sh による runner の登録が済んでいること（.runner が存在すること）。
#       未登録の場合は先に ./config.sh --url ... --token ... を実行する。
#
# 実行:
#   sudo bash runner-host-setup.sh
#   sudo RUNNER_USER=ci-runner RUNNER_DIR=/opt/runners/foo bash runner-host-setup.sh
#
# 既定値:
#   RUNNER_USER  sudo を呼び出したユーザー（$SUDO_USER）
#   RUNNER_DIR   $RUNNER_USER のホームディレクトリ配下の actions-runner
#
# 失敗したらその場で止まる（set -e）。何度実行しても同じ結果になる。

set -euo pipefail

SUDOERS_FILE=/etc/sudoers.d/github-runner

if [ "$(id -u)" -ne 0 ]; then
	echo "root で実行してください: sudo bash $0" >&2
	exit 1
fi

# runner を実行するユーザー。svc.sh install [user] に渡す値と一致させる。
RUNNER_USER="${RUNNER_USER:-${SUDO_USER:-}}"
if [ -z "$RUNNER_USER" ]; then
	echo "RUNNER_USER を決められません（sudo 経由でないため \$SUDO_USER が空です）。" >&2
	echo "RUNNER_USER=<user> を指定してください: sudo RUNNER_USER=ci-runner bash $0" >&2
	exit 1
fi

if ! home=$(getent passwd "$RUNNER_USER" | cut -d: -f6) || [ -z "$home" ]; then
	echo "ユーザーが見つかりません: $RUNNER_USER" >&2
	exit 1
fi

RUNNER_DIR="${RUNNER_DIR:-$home/actions-runner}"

if [ ! -x "$RUNNER_DIR/svc.sh" ]; then
	echo "runner ディレクトリが見つかりません: $RUNNER_DIR" >&2
	echo "RUNNER_DIR=<path> で指定してください。" >&2
	exit 1
fi

# .runner は config.sh が作る。未登録のまま svc.sh install しても起動できない。
if [ ! -f "$RUNNER_DIR/.runner" ]; then
	echo "runner が未登録です（$RUNNER_DIR/.runner がありません）。" >&2
	echo "先に config.sh で登録してください: cd $RUNNER_DIR && ./config.sh --url <URL> --token <TOKEN>" >&2
	exit 1
fi

echo "runner user: $RUNNER_USER"
echo "runner dir : $RUNNER_DIR"
echo

echo "== 1/5 パスワード不要 sudo =="
# ariga/setup-atlas が sudo install で /usr/local/bin へ atlas を置くため必須。
#
# 検証してから設置する。壊れた内容を /etc/sudoers.d/ へ置くと sudo 自体が使えなくなり、
# その端末からの復旧手段を失うため（tee してから visudo -c だと壊れた状態が一瞬でも残る）。
#
# 注意: NOPASSWD: ALL は、この runner で走る任意のワークフローに実質 root を与える。
# runner group の対象リポジトリを限定し、public リポジトリへ提供しないことが前提。
if [ -f "$SUDOERS_FILE" ] && grep -qE "^${RUNNER_USER}[[:space:]]+ALL=\(ALL\)[[:space:]]+NOPASSWD:[[:space:]]*ALL$" "$SUDOERS_FILE"; then
	echo "  既に設定済み: $SUDOERS_FILE"
else
	tmp=$(mktemp)
	printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$RUNNER_USER" >"$tmp"
	chmod 0440 "$tmp"
	visudo -c -f "$tmp"
	install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
	rm -f "$tmp"
	visudo -c
	echo "  設置: $SUDOERS_FILE"
fi

echo "== 2/5 Docker / Buildx / C コンパイラ =="
# docker.io 単体では buildx が入らず、COPY --chmod を含む Dockerfile が
# 「the --chmod option requires BuildKit」で失敗するため docker-buildx を明示する。
#
# build-essential は go test -race のため。競合検出は cgo（= gcc）を必要とし、
# actions/setup-go は Go ツールチェーンだけを入れて C コンパイラは入れない。
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-buildx build-essential
systemctl enable --now docker

echo "== 3/5 docker グループ =="
# usermod は既存プロセスに反映されない。この後で svc.sh install / start するので
# 新しいプロセスとして起動され、runner の再起動は不要になる。
# 既にサービスが動いている状態で実行した場合は 4/5 の svc.sh start では足りず、
# systemctl restart が必要になる（そのため 5/5 で稼働プロセスの Groups を検査する）。
usermod -aG docker "$RUNNER_USER"
echo "  $RUNNER_USER の所属: $(id -nG "$RUNNER_USER")"

echo "== 4/5 systemd サービス化 =="
cd "$RUNNER_DIR"
if [ -f .service ]; then
	echo "  既にサービス化済み: $(cat .service)"
else
	./svc.sh install "$RUNNER_USER"
fi
./svc.sh start

echo "== 5/5 確認 =="
docker --version
docker buildx version
gcc --version | head -1
echo "--- NOPASSWD sudo ---"
sudo -l -U "$RUNNER_USER" | grep -i nopasswd || echo "  NOPASSWD が見つかりません" >&2
echo "--- runner サービス ---"
unit=$(cat "$RUNNER_DIR/.service")
systemctl is-enabled "$unit" || true
systemctl is-active "$unit" || true
echo "--- runner のグループ反映（稼働プロセス）---"
# gsr-helper の doctor（job.dockergroup）と同じ判定。「グループ追加済みなのに
# permission denied が出続ける」= 稼働プロセスへの未反映を切り分けるため。
pid=$(pgrep -u "$RUNNER_USER" -f Runner.Listener | head -1 || true)
if [ -n "$pid" ]; then
	docker_gid=$(getent group docker | cut -d: -f3)
	# Groups 行だけを見る。status 全体を grep すると Pid や Uid の数値に当たる。
	groups_line=$(awk '/^Groups:/{$1=""; print}' "/proc/$pid/status")
	if printf ' %s ' $groups_line | grep -q " ${docker_gid} "; then
		echo "  OK: Runner.Listener (pid $pid) は docker グループを持っている"
	else
		echo "  NG: Runner.Listener (pid $pid) に docker グループが反映されていない" >&2
		echo "      sudo systemctl restart $unit を実行してください" >&2
	fi
else
	echo "  Runner.Listener が見つかりません（起動直後なら数秒待って systemctl status $unit を確認）" >&2
fi

echo
cat <<EOS

次にやること（このスクリプトからは検証できない）:

  ラベル
    runner のラベルに linux と x64 が付いていること。runs-on: [self-hosted, linux, x64]
    は 3 つを AND で要求し、欠けているとジョブはエラーにならず無期限に queued で止まる。
    journalctl -u $unit で Listening for Jobs の後に Running job が出れば付いている。

  runner group の対象リポジトリ（admin:org 権限が必要 / API から機械的に検証できない）
    org の Settings -> Actions -> Runner groups で確認する。
      - 対象リポジトリを「選択したリポジトリ」にし、使うリポジトリだけを明示的に追加する
      - public リポジトリへの提供は既定（提供しない）のまま変更しない
    NOPASSWD: ALL を入れた以上、ここが fork PR 経由で第三者のコードが
    この runner 上で走ることを防ぐ唯一の層になる。
EOS
