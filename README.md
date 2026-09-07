# actions-runner-setup

GitHub Actions の self-hosted runner ホストをセットアップするスクリプト。

ジョブ実行の前提（パスワード不要 sudo / Docker / Buildx / docker グループ / C コンパイラ）を整え、登録済みの runner を systemd サービスとして起動する。2 台目以降のホストはこれを実行すれば済む。

対象は **Linux + systemd、apt 系ディストリビューション**（Ubuntu 24.04 で実測）。

## 使い方

runner の登録（`config.sh`）が済んでいることが前提。未登録なら先に実行する。

```sh
cd ~/actions-runner
./config.sh --url https://github.com/<org> --token <TOKEN>
```

そのうえで:

```sh
sudo bash runner-host-setup.sh
```

runner のユーザーとディレクトリは環境変数で変えられる。

| 変数 | 既定値 | 説明 |
|------|--------|------|
| `RUNNER_USER` | `$SUDO_USER`（sudo を呼び出したユーザー） | runner を実行するユーザー。`svc.sh install [user]` に渡す値と一致させる |
| `RUNNER_DIR` | `$RUNNER_USER` のホーム配下の `actions-runner` | runner ディレクトリ |

```sh
sudo RUNNER_USER=ci-runner RUNNER_DIR=/opt/runners/foo bash runner-host-setup.sh
```

失敗したらその場で止まる（`set -e`）。何度実行しても同じ結果になる。

## やること

| # | 内容 | 理由 |
|---|------|------|
| 1 | `/etc/sudoers.d/github-runner` に `<user> ALL=(ALL) NOPASSWD: ALL`（0440） | `ariga/setup-atlas` が `sudo install` で `/usr/local/bin` へ atlas を置くため |
| 2 | `docker.io` + `docker-buildx` + `build-essential`、`systemctl enable --now docker` | `docker.io` 単体では buildx が入らない。`gcc` がないと `go test -race` が落ちる |
| 3 | `usermod -aG docker <user>` | ないと docker ソケットに繋げない |
| 4 | `svc.sh install <user>` → `svc.sh start` | systemd サービスとして常駐させる |
| 5 | 上記すべての確認 | 下記「確認していること」を参照 |

**3 → 4 の順序が重要。** `usermod` は既存プロセスに反映されないため、グループに入れてから runner を起動する。この順序なら runner の再起動は不要になる。すでにサービスが動いている状態で実行した場合は `svc.sh start` では足りないので、5 の検査が `NG` を出して `systemctl restart` を促す。

### sudoers の設置手順について

一時ファイルに書いて `visudo -c -f` で検証し、**合格したものだけを `install` する**。`tee` で置いてから `visudo -c` する順序だと、壊れた内容が `/etc/sudoers.d/` に一瞬でも入り、その時点で `sudo` 自体が使えなくなってその端末からの復旧手段を失う。設置後にも `visudo -c` で全体を再検証する。

## 確認していること

| 項目 | 判定方法 |
|------|---------|
| Docker | `docker --version` |
| Buildx | `docker buildx version` |
| C コンパイラ | `gcc --version` |
| パスワード不要 sudo | `sudo -l -U <user>` の `NOPASSWD` |
| runner サービス | `systemctl is-enabled` / `is-active` |
| docker グループの**稼働プロセスへの反映** | `/proc/<pid>/status` の `Groups` に docker の gid が入っているか |

最後の 1 つが重要で、「グループには追加済みなのに `permission denied` が出続ける」という一番はまりやすい状態を切り分ける。`id -nG <user>` は新しいセッションの値を返すため、**稼働中の `Runner.Listener` に反映されているかは分からない**。

## 欠けているものと症状

| 欠けているもの | 出るエラー |
|--------------|-----------|
| ラベル（`linux` / `x64`） | **エラーなし。** ジョブが無期限に `queued` のまま止まる |
| NOPASSWD sudo | `sudo: a password is required` |
| Docker | `docker: command not found` |
| Buildx | `the --chmod option requires BuildKit`（`COPY --chmod` を含む Dockerfile のビルド時） |
| docker グループ | `permission denied while trying to connect to the Docker daemon socket` |
| C コンパイラ（`gcc`） | `-race requires cgo; enable cgo by setting CGO_ENABLED=1` |

## スクリプトからは検証できないこと

### ラベル

runner のラベルに `linux` と `x64` が付いていること。`runs-on: [self-hosted, linux, x64]` は 3 つを AND で要求し、**欠けているとジョブはエラーにならず無期限に `queued`** で止まる。失敗として通知されないため最も気付きにくい。

`config.sh` の既定では付く。`journalctl -u <unit>` で `Listening for Jobs` の後に `Running job` が出れば付いている。

### runner group の対象リポジトリ

org の Settings → Actions → Runner groups で確認する。

| 項目 | 設定 |
|------|------|
| 対象リポジトリ | 「選択したリポジトリ」にし、runner を使うリポジトリだけを明示的に追加する |
| public リポジトリへの提供 | 既定（提供しない）のまま変更しない |

確認・変更には **org 管理者の権限**が必要で、API から触るには `admin:org` スコープが要る（`gh api orgs/<org>/actions/runner-groups` は権限がないと 403）。CI から機械的に検証できないため、**runner を追加・移動したときに手動で確認する**。

> **`NOPASSWD: ALL` は、この runner で走る任意のワークフローに実質 root を与える。** この設定を入れた以上、runner group の対象リポジトリ限定と public リポジトリへ提供しない既定が、fork PR 経由で第三者のコードがこのホスト上で走ることを防ぐ唯一の層になる。public リポジトリで使う runner では特に危険なため、可能なら NOPASSWD を必要なコマンドに限定する。

## 言語ツールチェーン

**ホストへの事前インストールは不要。** Go / Node / Terraform / Atlas はいずれも各 `setup-*` アクションがジョブ実行時に取得する。C コンパイラだけは `actions/setup-go` が入れないため例外で、このスクリプトが `build-essential` として入れる。

## 関連

runner の増減・稼働確認・障害切り分け・ディスク掃除は [gsr-helper](https://github.com/ousiassllc/gsr-helper)（TUI）で行う。このスクリプトが整える 4 項目（sudo / docker / buildx / docker グループ）は gsr-helper の doctor がジョブ実行の前提として検査する項目と対応している。

```sh
sudo gsr-helper -root ~/actions-runner
```
