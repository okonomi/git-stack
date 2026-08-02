# スナップショットテストのトピック別分割

## 背景

`test/cli_test.rb` は 1410 行・85 シナリオ、スナップショット `test/cli_test.rb.expected` は 915 行に達している。シナリオは修正のたび末尾に追記されてきたため、次の3つが問題になっている。

1. **関連シナリオが散在する** — `drop` は 467 行目と 673〜751 行目、`sync` は 434 行目と 820〜1032 行目に分かれている。既存カバレッジを探すのに全体を読む必要がある。
2. **1ファイルが長い** — 1410 行を開くコストが高い。
3. **スナップショット差分が読めない** — 915 行の `.expected` が一枚岩で、どこが動いたか追いにくい。

4. **コメントが位置に依存している** — `above` / `below` / `elsewhere` による参照が24箇所あり、うち7箇所は他セクションを指している。分割するとファイルをまたいで意味を失う。また共有テーマの説明が複数セクションに重複して書かれている。

## ゴール

シナリオをトピック別のファイルに分割し、スナップショットもファイル単位に分ける。**テストの挙動は一切変えない** — コードは純粋な再配置である。あわせて、分割で意味を失うコメントの参照を直し、重複している共有説明をファイル冒頭に集約する。

## 非ゴール

- シナリオの追加・削除・書き換え
- セットアップ重複の解消（名前付き fixture ヘルパーの導入）。今回は扱わない。
- コメント書式の全面的な統一（issue 参照の形式、末尾コメント49箇所、長い rationale の圧縮）。個々の rationale は逐語で保つ。
- `test/binary_test.sh` の変更
- `test/git-stack.rbs.expected` への影響。これは `bin/git-stack.rb` から生成される golden であり、テストファイルの構成とは無関係。

## 前提条件（検証済み）

空の Spinel プロジェクトを作って実地に確認した:

- `spin test [file..]` は `test/*.rb` を個別にビルドし、それぞれの `.expected` と突き合わせる。複数テストファイルは元からサポートされている。
- `require_relative` は Spinel・CRuby 双方で通る。
- `test/*.rb` のグロブは非再帰。`test/support/helper.rb` はテスト扱いされない。

## レイアウト

```
test/
  support/helper.rb   共通ヘルパー + 冒頭の解説コメント（現行 1〜103 行目相当）
  init_test.rb         8   trunk 検出と init の引数検証
  trunk_test.rb       12   複数 trunk の振る舞い（rename / 消失 / dedupe / 各 trunk が根）
  tree_test.rb         4   tree の描画（untracked 部分木・detached stack・親 cycle）
  nav_test.rb         12   up / down / parent の走査、detached root の扱い
  restack_test.rb      4
  sync_test.rb        10
  drop_test.rb         9
  track_test.rb        9   create / track / untrack / parent 設定・cycle 拒否
  refnames_test.rb    12   タグ衝突・HEAD の綴り・refname の綴り
  flags_test.rb        5   version / グローバルフラグ / 引数アリティ
```

合計 85。全シナリオの振り分けは巻末の付録に確定させてある。`tree_test.rb` と `restack_test.rb` は4シナリオと小さいが、コマンド別の受け皿として残す — 今後の追記が迷わず着地する先になる。

各テストファイルに対応する `.expected` を置く。`test/cli_test.rb` と `test/cli_test.rb.expected` は削除する。

`helper.rb` が `test/support/` にあるのは、`test/*.rb` のグロブに掛からないようにするためである。各テストファイルは冒頭で `require_relative "support/helper"` する。

`helper.rb` に移すもの: 現行冒頭の解説コメント、`$root` / `ENV["GIT_AUTHOR_DATE"]` / `ENV["GIT_COMMITTER_DATE"]` / `$gs` / `$repo` の初期化、`section` / `setup` / `gsq` / `run` / `show` / `gval` / `new_repo` / `commit`。各テストファイルには2〜3行の見出しコメントだけを置く。

## 振り分けルール

シナリオが**何を検証しているか**の主コマンドのファイルに置く。複数コマンドの一致を確認するもの（"tree and up agree on…", "restack and sync name the same root…"）は、そのバグが表面化するコマンド側に置く。

唯一の例外が `refnames_test.rb` で、これはコマンドではなく「名前解決の罠」という横断テーマで括る。タグがブランチ名を隠すケース、HEAD の綴りが ref と違うケース、refname の綴りが stored と違うケースは、コマンド別に散らすと再発時に一覧できなくなる。

## コメントの整理

`test/cli_test.rb` の 30%（1410 行中 421 行）はコメントで、内容は「どのバグの再発ガードか」を issue 番号付きで記した rationale である。削る対象ではない。手を入れるのは次の2点だけ。

### 1. ファイルをまたぐ参照を名指しに直す

他セクションを指している7箇所。`above` / `below` のような位置語をやめ、セクション名（必要ならファイル名も）で名指しする。うち6箇所は参照先が別ファイルへ移り、1箇所（`:157`）は逆に参照先が同一ファイルへ集まる。

| 現在の位置 | 参照の内容 | 分割後の関係 |
|---|---|---|
| `test/cli_test.rb:111` | "the sections below point it at a remote-tracking ref" | 対象セクションが init と refnames に割れる |
| `test/cli_test.rb:152` | "worse than the miss above" | refnames → init |
| `test/cli_test.rb:157` | "the HEAD and trunk-spelling sections elsewhere" | 参照先が同一ファイルに集まるので、位置語のまま残さず明示する |
| `test/cli_test.rb:265` | "The liveness re-check above" | refnames → trunk |
| `test/cli_test.rb:301` | "unlike the two above" | trunk → refnames |
| `test/cli_test.rb:503` | セクション名を直接名指し | flags → drop（ファイル名を添える） |
| `test/cli_test.rb:999` | 直前セクションへの参照 | sync → restack |

残る17箇所はセクション内の近くのコードを指しているので、そのまま移動する。

### 2. 共有テーマの説明をファイル冒頭に集約

「ユーザが打った名前ではなく git が保存している綴りに解決する」という話は6セクションに分散して書かれているが、それらは全て `refnames_test.rb` に集まる。ファイル冒頭に一度書き、各セクションの rationale はそのテーマの固有部分だけを残す。同じ扱いが必要になれば他のファイルでも行うが、明確に重複しているのは現状このテーマだけである。

現行冒頭の解説コメント（29 行、ハーネスの仕組みと再生成手順）は `support/helper.rb` に移す。各テストファイルには2〜3行の見出しコメントを置き、`spin test` / 再生成の手順は helper 側の一箇所だけに書く。

## 移行手順と等価性の証明

スナップショットが唯一のオラクルであることがリスクを生む。移動でシナリオを落としても、新しい `.expected` を生成し直せばバグごと祝福されて緑になる。そのため機械的な等価性チェックを必須とする。

**コミットを2つに分ける。** 等価性チェックが証明できるのはコードが逐語で移ったことだけで、コメントを書き換えてもスナップショットは緑のままである。検証できる変更と、目視レビューが要る変更を混ぜない。

### コミット1: 逐語移動

1. セクション本文をコメントごと逐語で移動する。**一文字も書き換えない。**
2. 各ファイルの `.expected` を `ruby test/xxx_test.rb > test/xxx_test.rb.expected` で生成する。
3. 新 `.expected` 群を連結し、`### <title>` ブロック単位で**元の順序に並べ替えて**、旧 `cli_test.rb.expected` と byte 一致することを diff で確認する。この照合スクリプトは使い捨てであり、コミットしない。

一致すれば、85 シナリオが1つも欠けず、1文字も変わらず移ったことの証明になる。CI の追随（後述）もこのコミットに含める。

### コミット2: コメントの整理

「コメントの整理」節の2点を適用する。このコミットは `.expected` を1バイトも変えてはならない — 変わったならコメント以外に手が入っている。`git diff` で `.expected` が無変更であることを確認したうえで、コメント差分を目視レビューする。

### 既知の例外

`version shows the program version` / `global flags are parsed with optparse` / `an unknown flag is rejected` の3セクションだけ `new_repo` を持たず、直前の drop シナリオが残したリポジトリで動いている。意図した依存ではなく追記の副作用である。

`flags_test.rb` では先頭に `new_repo` を置くため、この3ブロックは上の照合で差分候補になる。出力はリポジトリ非依存であるはずなので実際には一致する見込みだが、差分が出た場合は内容を確認したうえで判断する — 黙って新しい出力を承認しない。

## 追随が必要な箇所

- `.github/workflows/ci.yml:25` — `ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -` を `test/*_test.rb` のループに置き換える。1ファイルでも失敗したらジョブを落とすこと。
- `.github/workflows/ci.yml:230` — `spinel-doctor test/cli_test.rb` を全テストファイルと `test/support/helper.rb` に広げる。
- `.github/workflows/ci.yml:200` — `spin test` は複数ファイル対応済み。変更不要。
- `README.md:259-282` — スナップショットの説明と再生成コマンド。
- `test/binary_test.sh` の解説コメント内の `cli_test.rb` 参照（5, 32, 153, 256 行目）。
- `bin/git-stack.rb:1485` のコメント内参照。

## 完了条件

- `ruby test/<各ファイル>.rb | diff -u test/<各ファイル>.rb.expected -` が全て通る
- `spin test` が全ファイル通る
- 上記の等価性照合が byte 一致する（flags の3ブロックを除き、除く場合はその差分を説明できる）
- `test/binary_test.sh | diff -u test/binary_test.sh.expected -` が通る（無変更の確認）
- `spinel-doctor` が全テストファイルで通る
- コミット2 の `git diff` に `.expected` の変更が1件も含まれていない
- 分割後のファイルに、他ファイルを指す `above` / `below` / `elsewhere` が残っていない

## 付録: シナリオの振り分け

現行 `test/cli_test.rb` の出現順に番号を振ったもの。実装はこの表どおりに動かす。

| # | セクション | 移動先 |
|---|---|---|
| 1 | init auto-detects the trunk | init |
| 2 | init prefers the remote's default branch over main | init |
| 3 | init ignores the remote's default branch when it has no local ref | init |
| 4 | init reads the remote's default branch past a local branch named origin/\<name\> | init |
| 5 | init resolves the remote's default branch to the spelling git stores | refnames |
| 6 | init dies when the remote's default branch is the only candidate | init |
| 7 | init records multiple trunks and lists them | init |
| 8 | init rejects a non-existent trunk | init |
| 9 | init rejects a duplicate trunk name | init |
| 10 | init rejects a trunk whose spelling is not the stored refname | refnames |
| 11 | an already-duplicated trunk list is deduped on read | trunk |
| 12 | sync re-detects a renamed trunk instead of reparenting onto its old name | trunk |
| 13 | a vanished secondary trunk is dropped from the trunk list | trunk |
| 14 | a trunk that is gone with no replacement is an error, and config is kept | trunk |
| 15 | a trunk whose stored spelling is not the refname is not live | refnames |
| 16 | trunk auto-detect will not store a name the refs do not have | refnames |
| 17 | a branch one level down does not stand in for its parent name | trunk |
| 18 | tree renders each trunk as its own root | trunk |
| 19 | an emptied stackParent is read as untracked, not as the primary trunk | trunk |
| 20 | restack stops at the secondary trunk it rests on | trunk |
| 21 | down and parent treat every trunk as a bottom | trunk |
| 22 | down and parent walk an untracked branch to the trunk it rests on | nav |
| 23 | track with no argument picks the trunk the branch rests on | track |
| 24 | sync heals an orphan onto the trunk its stack rests on | trunk |
| 25 | sync still heals a main-based orphan onto main when a second trunk exists | trunk |
| 26 | drop reconnects children to the trunk the dropped branch rested on | drop |
| 27 | version shows the program version | flags |
| 28 | global flags are parsed with optparse | flags |
| 29 | an unknown flag is rejected | flags |
| 30 | commands reject extra arguments and flags they do not take | flags |
| 31 | an empty argument is not counted as a positional | flags |
| 32 | create records the parent and checks out the branch | track |
| 33 | create rejects an existing branch | track |
| 34 | tree renders the whole stack | tree |
| 35 | down / up navigate the stack | nav |
| 36 | up with multiple children requires a choice | nav |
| 37 | restack replays descendants onto the updated parent | restack |
| 38 | restack aborts cleanly on a conflict | restack |
| 39 | parent shows and sets the parent | track |
| 40 | untrack removes the metadata | track |
| 41 | tree keeps the subtree of a branch that was untracked | tree |
| 42 | restack and sync name the same root tree draws, with an untracked parent | sync |
| 43 | a detached stack is drawn once, from its top, whatever its branches are named | tree |
| 44 | tree renders a hand-edited parent cycle instead of dropping it | tree |
| 45 | drop splices the bottom branch out, reparenting children onto trunk | drop |
| 46 | drop a middle branch reconnects children to the grandparent | drop |
| 47 | drop reparents every child of a branch with multiple children | drop |
| 48 | drop --delete removes the branch ref after splicing | drop |
| 49 | drop falls back to trunk when the dropped branch's own parent is gone | drop |
| 50 | drop --delete on the current branch survives a dead recorded parent | drop |
| 51 | drop refuses a trunk and a non-existent branch | drop |
| 52 | drop with no argument splices the current branch | drop |
| 53 | parent rejects an indirect cycle | track |
| 54 | track rejects an indirect cycle | track |
| 55 | track refuses to track a trunk | track |
| 56 | parent refuses to reparent a trunk | track |
| 57 | a trunk's recorded parent is ignored by tree and restack | trunk |
| 58 | restack leaves an untracked branch alone | restack |
| 59 | sync reparents an orphaned branch onto trunk and restacks it | sync |
| 60 | sync heals a multi-level orphan chain in one pass | sync |
| 61 | sync reports a conflict the same way restack does | sync |
| 62 | tree shows a branch whose parent was deleted, then sync fixes it | sync |
| 63 | sync heals an orphan in another stack when run from the trunk | sync |
| 64 | sync heals every orphaned stack in one pass, without repeating its own | sync |
| 65 | sync recovers a branch whose parent was squash-merged and deleted | sync |
| 66 | sync fast-forwards a branch fully merged into its parent | sync |
| 67 | restack falls back to merge-base when stackBase is unrecorded | restack |
| 68 | sync clamps a stale stackBase to the merge-base instead of re-applying parent commits | sync |
| 69 | tree keeps a branch whose name collides with a tag | refnames |
| 70 | trunk detection ignores a tag sharing a branch's name | refnames |
| 71 | commands read HEAD past a tag sharing the branch's name | refnames |
| 72 | a detached HEAD is still detached without --short | refnames |
| 73 | HEAD spelled differently from the ref still names the branch | refnames |
| 74 | HEAD spelled differently outside ASCII still names the branch | refnames |
| 75 | restack replays onto the parent branch, not a tag that shadows it | refnames |
| 76 | reparenting anchors the base to the parent branch, not a tag that shadows it | refnames |
| 77 | up and down round-trip through an untracked parent | nav |
| 78 | parent and down name the untracked parent they walk to | nav |
| 79 | up lists a detached root alongside the trunk's tracked children | nav |
| 80 | up offers a detached root only from the trunk its stack rests on | nav |
| 81 | parent notes a parent whose ref is gone | nav |
| 82 | up \<name\> reaches another trunk's detached root; the menu still refuses it | nav |
| 83 | tree and up agree on which trunk a detached root belongs to | nav |
| 84 | up refuses a detached root whose ref no longer exists (a phantom node) | nav |
| 85 | up orders a trunk's tracked child before its detached roots, sorted | nav |

判断が分かれうる3件について、根拠を残しておく。

- **#5 / #10 / #15 / #16**（trunk の綴り解決）は init / trunk ではなく refnames に置く。これらは「ユーザが打った名前ではなく git が保存している綴りに解決する」という一つのルールの現れであり、#73 / #74（HEAD の綴り）と同じ話をしている。離すと再発時に片方しか見つからない。
- **#42**（restack and sync name the same root）は tree の描画を見ているが、検証しているのは restack / sync の root 選択なので sync に置く。
- **#83**（tree and up agree）はバグが出るのが up 側のメニューなので nav に置く。
