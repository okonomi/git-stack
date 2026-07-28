# untracked な親を挟んだときの navigation 設計（issue #85）

## 背景

`main -> feat-a -> feat-b -> feat-c` で `feat-a` を `untrack` すると、`feat-a` は
「存在するがどこからも tracked されていない親」になる。この状態で `tree` の描画と
`down`/`up` の移動が食い違う。

issue #58 / #80（PR #84）で `tree` と `restack`/`sync` の「root の位置」は揃った。
#80 は表示だけを扱い、`down`/`parent` は「一段外側の同じ問い」として意図的にスコープ外に
した。本 spec はその残りを閉じる。

### 現象 A: `down` は tree に一度も現れないブランチに降りる

```
$ git stack tree
  main (trunk)
  * feat-b (1 commit(s)) (parent 'feat-a' is untracked)
      feat-c (1 commit(s))

$ git stack parent
feat-a

$ git stack down
Switched to branch 'feat-a'
```

### 現象 B: tree が trunk 直下に描いた行に `up` で辿り着けない

```
$ git stack tree          # main にいる状態
* main (trunk)
    feat-b (1 commit(s)) (parent 'feat-a' is untracked)

$ git stack up
error: no branch stacked on top of 'main'
```

`children_of(main)` は feat-b を含まない（feat-b が記録している親は feat-a）ため。
往復が切れているのは trunk と detached root の間だけで、feat-a からの `up` では
feat-b に戻れる。

## 採用する定義

**untracked な親は隠さず注記する。navigation は tree が描いた行と一致させる。**

issue の3案のうち案2。案1（`down`/`parent` も untracked な親を飛ばして trunk を指す）を
採らない理由は、`tree` 自身が `(parent 'feat-a' is untracked)` と feat-a を**名指しして
いる**こと。そこで `parent` が `main` と答えると、既存の表示との間に新しい矛盾が生まれる。
また feat-a は `restack` が feat-b を実際に乗せる先（`restacking feat-b onto feat-a`）
でもあり、そこへ降りられること自体は正しい。

したがって:

- `down`/`parent` は実際の親（feat-a）に降りたまま、`tree` と同じ注記を添える。
- `up` は detached root を trunk の子として拾い、B の矛盾を解消する。

## 1. 注記の文言を1箇所にする

`(parent 'x' is untracked)` と ``(parent 'x' missing; run `git stack sync`)`` の文字列は
現在 `print_tree_row` の中にだけある。これを

```ruby
def parent_note(branch, topology)
```

として切り出し、`tree` と `parent`/`down` の両方がこの関数を呼ぶ。述語は既存の
`StackTopology#untracked_parent?` / `#parent_missing?` をそのまま使う。

これは重複除去が目的ではない。「`parent` は `tree` と同じことを言う」という不変条件を、
**文言のコピーではなく同一の呼び出し**で保証するため。片方だけ直して食い違う経路を構造的に
消す。

`print_tree_row` の現在の分岐（untracked は `branch?(parent)` 側、missing は `elsif` 側）は
`untracked_parent?` が `branch?(parent)` を、`parent_missing?` が `!branch?(parent)` を
それぞれ内部で見ているので、単一関数で正確に再現できる。

戻り値は着色済みの注記文字列、該当しなければ `""`。

## 2. A: `down` / `parent` に注記を出す

- **`effective_parent` は一切変更しない。** feat-a に降りる挙動はそのまま。
  「parentless なブランチは trunk に載る」ルールの唯一の家、という同関数のコメントが
  宣言している seam を崩さない。
- `cmd_parent`（引数なしの読み取り時のみ）と `cmd_down` が topology を1つ読み、
  `parent_note` が非空なら `info` で **stderr** に出す。
- `git stack parent` の **stdout は `feat-a` のまま**。スクリプトが読む値は変わらない。
- `cmd_down` は `branch_exists?` の die を先に通すので、missing 注記は down では実質
  到達しない（die のメッセージが既に同じことを言っている）。down で出るのは untracked の
  注記だけ。
- 親を設定する側（`git stack parent <new-parent>`）には注記を出さない。読み取り経路のみ。
- コスト: `down`/`parent` に config スキャン + `for-each-ref` が各1回増える。対話コマンド
  なので無視できる。

## 3. B: `up` が detached root を trunk の子として拾う

トップレベルの `children_of(parent, trunks)`（`up` 専用の one-shot パス）を拡張する。

- `parent` が trunk のときだけ、`topology.detached_roots` のうち
  `containing_trunk(root, trunks) == parent` のものを追加する。
- 対象は `detached_roots` **全部**。untracked 親の root も orphan（親が削除済み）も含む。
  規則は「`up` は `tree` が trunk 直下に描く行をそのまま提供する」の一行で言い切れる形に
  する。
- 順序は tree の描画順に合わせる: tracked な子（ソート済み）→ detached root（ソート済み）。
  `up` が複数候補を出すときのメニューが tree の行順と一致する。
- 重複の心配はない。`detached_roots` は「親が trunk の root」を既に落としている
  （`next if trunk?(parent_of(root))`）ので、`children_of(trunk)` と交わらない。
- `up <name>` で detached root を名指しする経路も同じリストを見るので自動的に通る。
- `parent` が trunk でない場合の挙動は変わらない。detached root が接続されるのは trunk の
  層だけ。

### multi-trunk の割り当て

`tree` は detached root を全 trunk の後ろにまとめて描くだけで、どの trunk に属するかを
言っていない。`up` は HEAD を動かすので、ここは決める必要がある。

`containing_trunk`（履歴上もっとも近い trunk）で割り当てる。issue #73 で `track` /
`sync` の orphan heal / `drop` の子の再接続が既にこの判断をしており、「develop 基盤の
スタックを黙って main に引きずる」のを避けるために導入されたもの。HEAD を動かす `up` は
同じ配慮が要る。単一 trunk リポでは `containing_trunk` が短絡するので git 呼び出しは
増えない。

結果として `up` は `tree` より厳密になる（tree は帰属を言わない）。これは矛盾ではなく、
tree 側の曖昧さが残るだけ。

## 4. テスト

`test/cli_test.rb` はゴールデントランスクリプト方式（`ruby test/cli_test.rb` の出力を
`test/cli_test.rb.expected` と diff）。セクションを追加して `.expected` を再生成する。

追加するセクション:

1. **往復が繋がったこと**を1セクションで見せる:
   `main` → `up` → feat-b → `down` → feat-a → `down` → main。
   回帰は「各コマンドの出力の食い違い」としてしか見えないので、#80 のセクションと同じく
   1つのトランスクリプトに並べる必要がある。
2. `tree` と `parent` を隣り合わせ、同じ注記が出ていることを差分に出す。
3. 親が削除済み（missing）のときの `parent` の注記。
4. multi-trunk: detached root がその containing trunk の `up` からだけ見えること。

### 通すべきCI

- CRuby スナップショット差分（`ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -`）
- Spinel コンパイル + `spin test`
- ネイティブバイナリテスト（`test/binary_test.sh`）: 配列の連結が Spinel の poly-array
  slow path に落ちる類の不具合はコンパイル済みバイナリでしか出ないため、B の実装では
  特にここを確認する。
- RBS ゴールデン（`test/git-stack.rbs.expected`）: シグネチャが動いたら再生成し、untyped
  カウントのラチェット（現在 39、下がるのは可・上がるのは不可）を確認する。

## スコープ外

- `tree` の描画は変更しない（#58 / #80 で確定済み）。
- `restack` / `sync` の挙動は変更しない。feat-b は引き続き feat-a に乗る。
- `effective_parent` / `climb_to_root` のルール自体は変更しない。
