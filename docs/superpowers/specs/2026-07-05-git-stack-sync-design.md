# `git stack sync`: 孤立ブランチの自動再親付け + restack

## 背景・課題

git-stack のワークフローでは、スタックの下位ブランチ(例: `feature-a`)がレビューを通り
`main` にマージされたら、そのブランチをローカルで `git branch -d` などで削除する。

このとき `git branch -d` は git の標準動作として `branch.feature-a.*` の git config
セクションごと削除する(実験で確認済み)。しかし、上位ブランチ(`feature-b`)が持つ
`branch.feature-b.stackParent = feature-a` という参照は変更されないため、
「親ブランチの実体が存在しない」孤立(orphan)状態になる。

現状のコマンドはこの状態にうまく対応できない:

- `git stack restack` は `parent_from` で取得した親が `branch_exists?` で false の場合、
  対象ブランチのrebaseを黙って素通りする。何も直さない。
- `git stack tree` は `trunk` の直接の子(`children_from(scan, trunk)`)からのみ
  再帰描画するため、孤立した `feature-b` は出力から完全に消える
  (親 `feature-a` の config セクション自体が削除済みで、trunk からの経路が
  途切れているため)。これは実装上のバグである。

そのため、マージ済みブランチを削除した後にユーザーは
「`feature-b` に checkout して `git stack parent main` (または `track main`) を実行し、
`git stack restack` する」という手順を手動で行う必要があった。これをワンタッチで
行えるようにする。

## 目的

`git stack sync` という新しいサブコマンドを追加し、現在チェックアウト中のブランチが
属するスタック内で「親ブランチが存在しないブランチ」を検知したら、自動的に
trunk へ再親付け(`stackParent` を書き換え)した上で、通常の restack と同じロジックで
子孫まで連鎖的に rebase する。

あわせて `git stack tree` の表示漏れを修正し、孤立ブランチが常に見える状態にする。

## スコープ

含む:

- 新規サブコマンド `git stack sync`
  - 対象は `restack` と同じく「現在チェックアウト中のブランチが属するスタックのみ」
    (リポジトリ全体の全スタックは対象にしない)
- `git stack tree` の孤立ブランチ表示修正
- `git stack help` / `README.md` への反映
- `test/cli_test.rb` へのシナリオ追加とスナップショット更新

含まない(YAGNI):

- trunk にマージ済みだがまだローカルに残っているブランチの自動検出・自動削除
  (ブランチ削除は引き続きユーザーが手動で行う)
- リモートの fetch/prune
- 孤立ブランチをtrunk以外(祖先の祖先など)に再親付けする高度な推測
  (親ブランチの config セクションは削除時に消えるため、どのみち元の祖先情報は
  復元不能。trunkへの付け替えが唯一の実用的なデフォルト)

## 設計

### 1. `git stack sync` の処理フロー

```
cmd_sync:
  trunk    = trunk_branch
  original = current_branch
  root     = stack_root(original, trunk)     # restackと同じ探索
  scan     = scan_stack_config
  sync_subtree(root, scan, trunk, visited = {})
  checkout!(original)                        # 失敗時は restack と同じ文言でdie
  info "done."

sync_subtree(branch, scan, trunk, visited):
  return if visited[branch]
  visited[branch] = true

  parent = parent_from(scan, branch)
  if !parent.empty? && !branch_exists?(parent):
    info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
    die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
    parent = trunk

  if !parent.empty? && branch_exists?(parent):
    behind = commit_count(branch, parent)
    if behind > 0:
      info "restacking #{branch} onto #{parent}"
      unless git_ok("git rebase #{parent} #{branch}"):
        git_ok("git rebase --abort")
        die("conflict while rebasing '#{branch}' onto '#{parent}'.\n"
            "Resolve it manually with:\n"
            "    git checkout #{branch} && git rebase #{parent}\n"
            "then re-run 'git stack sync'.")

  children_from(scan, branch).each do |child|
    sync_subtree(child, scan, trunk, visited)
```

- 親不在検知後の rebase 部分は既存 `restack_subtree` と同一ロジック。実装時に
  重複を避けるため、`restack_subtree` に「親不在ならtrunkへ付け替える」フラグ引数を
  持たせて `restack`/`sync` 両方から呼ぶ形にするか、`sync_subtree` として複製するかは
  実装時の裁量とする(挙動としては上記の通り)。
- `set_parent` / `branch_exists?` / `commit_count` / `children_from` / `parent_from` /
  `stack_root` はすべて既存のヘルパーをそのまま再利用する。
- config の書き換えはconfirmationなしで即座に行う(既存の `restack` が確認なしで
  rebaseすることと一貫させる)。ただし `info` で必ず何をしたか出力する。

### 2. `git stack tree` の孤立表示修正

`cmd_tree` は現在 `children_from(scan, trunk)` から辿れる範囲しか描画しない。
これに加えて、`scan` 全体から「親が空でなく、かつ `branch_exists?(parent)` が false」
であるブランチを集め、trunk の子と同列の追加ルートとして描画する。

- 収集条件: `scan` の各エントリ `(branch, parent)` について
  `!parent.empty? && !branch_exists?(parent)` なもの。
- 描画: 通常の `print_subtree` 呼び出しと同じインデント(`"  "`)で追加ルートとして出力。
- 注記: `print_subtree` 内で「親が存在しない」ケースの `extra` 文言を追加する
  (現状は該当ケースで `extra` が空文字のまま何も表示されない):
  ```
  #{C_YELLOW}(parent '#{parent}' missing; run `git stack sync`)#{C_RESET}
  ```
- 出力イメージ:
  ```
  main (trunk)
    feature-b (parent 'feature-a' missing; run `git stack sync`)
      feature-c (1 commit(s))
  ```

### 3. エラー処理・エッジケース

- **rebase競合**: `restack` と同じ挙動(abort + 手動解決の案内 + 再実行を促す)。
  途中まで書き換えた `stackParent` はそのまま残るため、`sync` の再実行は
  べき等に続きから進行できる。
- **多段の孤立**(例: `feature-a` と `feature-b` の両方が削除され、`feature-c` のみ残存):
  再帰呼び出しの中で `feature-c` も同じ条件に該当するため、1回の `sync` 実行で
  まとめて trunk 付け替え + rebase される。
- **孤立していない通常ブランチ**: 付け替えは発生せず、`restack` と全く同じ
  (behindがあればrebase、なければ何もしない)。
- **未追跡ブランチ**(`stackParent` 未設定): 何もしない。trunkへのフォールバックは
  行わない(既存方針を踏襲)。
- **checkout失敗**: 最後に元のブランチへ戻れない場合、`restack` と同じ文言でdie。
- **`set_parent` 失敗**: 他コマンドと同様 `die`。

### 4. ヘルプ・ドキュメント・テスト

- `cmd_help` のコマンド一覧に追加:
  ```
  sync                   Restack the current stack, reparenting branches
                         whose parent was deleted onto trunk.
  ```
- `README.md` のコマンド表に `git stack sync` の行を追加。
- `README.md` の Walkthrough に、マージ済みブランチ削除後の一手として追記:
  ```sh
  git branch -d feature-a         # already merged, delete it
  git stack sync                  # reparent feature-b onto main and restack
  ```
- `test/cli_test.rb` に新規シナリオを追加:
  1. `main -> feature-a -> feature-b` のスタックを作成
  2. `feature-a` を `main` にマージして `git branch -d` で削除
  3. `feature-b` にcheckoutして `git stack sync` を実行
  4. `git stack tree` で `feature-b` が `main` 直下に表示されることを確認
  5. 孤立表示修正の回帰確認として、`sync` 前の `tree` 出力(孤立表示付き)も
     スナップショットに含める
  - `spin test --regen` でスナップショット (`test/cli_test.rb.expected`) を更新。

## 非対象・既知の制約

- 3世代以上前の祖先情報は、親ブランチ削除時にconfigごと失われるため復元不可能。
  常にtrunkへの付け替えが行われる(祖先の祖先への付け替えはしない)。
- マージ済みだが削除されていないブランチの自動検出・削除は行わない
  (今回のユーザーの要望は「削除した後」の後始末に限定されるため)。
