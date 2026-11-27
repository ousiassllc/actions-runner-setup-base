#!/usr/bin/env bash
# GitHub Actions self-hosted runner ホストのセットアップ（Linux + systemd / apt 系）
#
# ジョブ実行の前提（パスワード不要 sudo / Docker / Buildx / docker グループ / C コンパイラ）と、
# ジョブ shell から node / npx を引くための PATH（runner の .env）を整え、登録済み runner を
# systemd サービスとして起動する。最後にコンテナ内の名前解決を含む状態確認を行う。
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
# 設定が済んでも 5/5 の確認で NG が 1 件でもあれば、最後に終了コード 1 で終わる。

set -euo pipefail

SUDOERS_FILE=/etc/sudoers.d/github-runner

# 5/5 の確認で NG を数える。set -e では止めず、全項目を見せてから最後に終了コードへ反映する。
ng_count=0
ng() {
	echo "  NG: $*" >&2
	ng_count=$((ng_count + 1))
}

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

# 相対パスで渡されても、4/5 の cd 後に $RUNNER_DIR/.env を引けるよう絶対パスにしておく。
RUNNER_DIR=$(cd -P -- "$RUNNER_DIR" && pwd)

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
#
# 設置先は固定名の 1 ファイル。別の RUNNER_USER で再実行すると前のユーザーの行は置き換わる。
sudoers_line="$RUNNER_USER ALL=(ALL) NOPASSWD: ALL"
if [ -f "$SUDOERS_FILE" ] && grep -qxF "$sudoers_line" "$SUDOERS_FILE"; then
	echo "  既に設定済み: $SUDOERS_FILE"
else
	tmp=$(mktemp)
	# visudo -c -f が失敗して set -e で終わるときも一時ファイルを残さない。
	trap 'rm -f "$tmp"' EXIT
	printf '%s\n' "$sudoers_line" >"$tmp"
	chmod 0440 "$tmp"
	visudo -c -f "$tmp"
	install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
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

echo "== 4/5 PATH 設定と systemd サービス化 =="
# ジョブの shell は非ログイン・最小環境で起動するため、fish の fnm 初期化も
# shell/paths.sh も読まれず node / npx が見えない（exit 127）。
# runner の .env に PATH を書けばジョブへ引き継がれる。fnm の aliases/default は
# node の更新に追従するシンボリックリンクなので、バージョンを固定せずに済む。
# PATH= 行は置き換えるだけで、何度実行しても重複しない。
env_file="$RUNNER_DIR/.env"
runner_path="$home/.local/share/fnm/aliases/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
path_changed=0
if [ ! -e "$env_file" ]; then
	install -m 644 -o "$RUNNER_USER" /dev/null "$env_file"
fi
if grep -qxF "PATH=$runner_path" "$env_file"; then
	echo "  $env_file の PATH は設定済み"
else
	sed -i '/^PATH=/d' "$env_file"
	# 末尾が改行で終わっていないと直前の行に連結されてしまう。
	if [ -s "$env_file" ] && [ -n "$(tail -c1 "$env_file")" ]; then
		echo >>"$env_file"
	fi
	echo "PATH=$runner_path" >>"$env_file"
	path_changed=1
	echo "  $env_file に PATH を設定した"
fi

cd "$RUNNER_DIR"
if [ -f .service ]; then
	echo "  既にサービス化済み: $(cat .service)"
else
	./svc.sh install "$RUNNER_USER"
fi
unit=$(cat .service)
# .env は runner の起動時にだけ読まれる。稼働中だった場合は再起動が必要だが、
# 実行中のジョブ（Runner.Worker）を落とさないよう、ジョブが無いときだけ行う。
was_active=0
systemctl is-active --quiet "$unit" && was_active=1
./svc.sh start
if [ "$path_changed" -eq 1 ] && [ "$was_active" -eq 1 ]; then
	if pgrep -u "$RUNNER_USER" -f Runner.Worker >/dev/null; then
		echo "  ジョブ実行中のため runner を再起動していません。PATH を反映するには" >&2
		echo "  ジョブが無くなってから sudo systemctl restart $unit を実行してください" >&2
	else
		systemctl restart "$unit"
		echo "  PATH 反映のため runner を再起動した"
	fi
fi

echo "== 5/5 確認 =="
docker --version
docker buildx version
gcc --version | head -1
echo "--- ジョブ shell（非ログイン・最小環境）から node / npx ---"
# ジョブ shell 相当の環境で、.env の PATH だけを頼りに node / npx が引けるかを見る。
# command -v は複数の名前を渡すと 1 つでも見つかれば成功を返すため、1 つずつ検査する。
job_path=$(grep '^PATH=' "$env_file" | cut -d= -f2-)
for cmd in node npx; do
	if ! sudo -u "$RUNNER_USER" -H env -i HOME="$home" PATH="$job_path" bash --noprofile --norc -c 'command -v "$1"' _ "$cmd"; then
		ng "$cmd が見えません（fnm で node を入れ、fnm default を設定してください）"
	fi
done
echo "--- コンテナ内の名前解決 ---"
# docker build 中の DNS 障害は、デプロイが長時間待ってから落ちて初めて気づくため
# セットアップ時点で検知する。自動修正はしない（/etc/docker/daemon.json の "dns" はホスト固有）。
# イメージを用意できない場合（Docker Hub への到達性・レート制限・daemon 不調）は DNS の
# 不具合と取り違えないよう、別の NG として扱う。
if ! docker image inspect alpine >/dev/null 2>&1 && ! docker pull -q alpine >/dev/null 2>&1; then
	ng "alpine イメージを用意できません（docker daemon の状態と Docker Hub への到達性を確認してください。DNS は未検査）"
elif ! docker run --rm alpine nslookup proxy.golang.org >/dev/null 2>&1; then
	ng "コンテナから名前解決できません（docker の dns 設定を確認: README「欠けているものと症状」の「コンテナの DNS」）"
fi
echo "--- NOPASSWD sudo ---"
sudo -l -U "$RUNNER_USER" | grep -i nopasswd || ng "NOPASSWD が見つかりません"
echo "--- runner サービス ---"
systemctl is-enabled "$unit" || ng "$unit が enable されていません"
systemctl is-active "$unit" || ng "$unit が active ではありません"
echo "--- runner のグループ反映（稼働プロセス）---"
# gsr-helper の doctor（job.dockergroup）と同じ判定。「グループ追加済みなのに
# permission denied が出続ける」= 稼働プロセスへの未反映を切り分けるため。
pid=$(pgrep -u "$RUNNER_USER" -f Runner.Listener | head -1 || true)
if [ -n "$pid" ]; then
	docker_gid=$(getent group docker | cut -d: -f3)
	# Groups 行だけを見る。status 全体を grep すると Pid や Uid の数値に当たる。
	groups_line=$(awk '/^Groups:/{$1=""; print}' "/proc/$pid/status")
	case " $groups_line " in
	*" $docker_gid "*)
		echo "  OK: Runner.Listener (pid $pid) は docker グループを持っている"
		;;
	*)
		ng "Runner.Listener (pid $pid) に docker グループが反映されていない（sudo systemctl restart $unit を実行してください）"
		;;
	esac
else
	ng "Runner.Listener が見つかりません（起動直後なら数秒待って systemctl status $unit を確認）"
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

if [ "$ng_count" -gt 0 ]; then
	echo >&2
	echo "確認で NG が ${ng_count} 件ありました。上の NG を解消してから再実行してください。" >&2
	exit 1
fi
