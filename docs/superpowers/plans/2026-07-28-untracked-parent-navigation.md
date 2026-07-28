# untracked な親の navigation 実装計画（issue #85）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tree` が描いた行と `down`/`parent`/`up` の移動を一致させる ―― untracked な親は隠さず注記し、`up` は trunk 直下に描かれた detached root へ到達できるようにする。

**Architecture:** 注記の文言を `parent_note` として1箇所に切り出し、`tree` と `parent`/`down` が同じ関数を読む。親の解決ロジック（`effective_parent`）は変更しない。`up` 専用の one-shot パスである トップレベル `children_of` を、trunk のときだけ `containing_trunk` で割り当てた detached root を足すよう拡張する。

**Tech Stack:** Ruby（Spinel が受け付ける部分集合）、git CLI、ゴールデントランスクリプトのスナップショットテスト。

## Global Constraints

- 対象ファイルは `bin/git-stack.rb`、`test/cli_test.rb`、`test/cli_test.rb.expected`、`rbs/git-stack.rbs`、必要なら `test/git-stack.rbs.expected`。
- **Ruby コマンドは必ず `mise x --` を前置する**（例: `mise x -- ruby test/cli_test.rb`）。
- `bin/git-stack.rb` は Spinel が受け付ける Ruby の部分集合で書く: `File`/`Dir`/`tmpdir` を使わない、backtick と `system` で git を叩く、`loop do ... end` の中で `return` しない。
- **配列を連結しない。** この repo は `Array#+` も `Array#concat` も一度も使っていない。要素追加は `each` + `<<` で書く。poly-array メソッド（`uniq`/`select`/`reject`/`compact`/`flatten`/`take`/`zip`/`index`/`reduce`/`sort_by`）は具象レシーバの上でしか Spinel が解決できず、外すとコンパイルは通ってネイティブバイナリだけが `NoMethodError` で死ぬ。
- スナップショットは手書きの期待値を持たない。**スナップショットが oracle**。意図した変更のあとに再生成する:
  `mise x -- ruby test/cli_test.rb > test/cli_test.rb.expected`
- 検証コマンド:
  - `mise x -- ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -`
  - `spinel-doctor bin/git-stack.rb && spinel-doctor test/cli_test.rb`
  - `spin build && test/binary_test.sh | diff -u test/binary_test.sh.expected -`
  - `spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && diff -u test/git-stack.rbs.expected /tmp/emitted.rbs`
- emitted RBS ゴールデンの `untyped (slow path)` 行数は **ラチェット: 下がるのは可・上がるのは不可**。Task 1 実施時にこのブランチで計測した実測値は **35**（`ci.yml` のコメントが言う 39 は別の数え方なので、比較対象は 35 のほう）。上がったら widening の起点を探して潰すまでマージしない。
- ブランチは `fix/untracked-parent-navigation`（作成済み、spec がコミット済み）。

## File Structure

| ファイル | 責務 | この計画での変更 |
|---|---|---|
| `bin/git-stack.rb` | CLI 本体（単一ファイル構成、この repo の既存パターン） | `parent_note` を新設、`print_tree_row` / `cmd_parent` / `cmd_down` / `children_of` を変更 |
| `test/cli_test.rb` | ゴールデントランスクリプトの生成 | セクションを4つ追加 |
| `test/cli_test.rb.expected` | スナップショット（oracle） | 再生成 |
| `rbs/git-stack.rbs` | Spinel に食わせる手書き型シード（**入力**） | `parent_note` / `untracked_parent?` / `detached_roots` のピンを追加 |
| `test/git-stack.rbs.expected` | Spinel が**出力**した型のゴールデン | 差分が出たら再生成（`rbs/` の下には絶対に置かない） |

単一ファイル構成は既存の設計判断なので分割しない。

---

### Task 1: 注記の文言を `parent_note` に切り出す（挙動不変のリファクタ）

**Files:**
- Modify: `bin/git-stack.rb:1280-1312`（`print_tree_row`）
- Modify: `rbs/git-stack.rbs`
- Test: `test/cli_test.rb.expected`（既存スナップショットが**そのまま**通ることが本タスクのテスト）

**Interfaces:**
- Consumes: `StackTopology#parent_of` / `#untracked_parent?` / `#parent_missing?`、`yellow`、定数 `PROG`（いずれも既存）
- Produces: `parent_note(branch, topology) -> String` ―― 注記文字列（着色済み）、該当なしは `""`。Task 2 が使う。

このタスクは挙動を1バイトも変えない。既存のゴールデンが唯一の安全網なので、**先に green を確認してから**変更する。

- [ ] **Step 1: 変更前のベースラインが通ることを確認する**

Run: `mise x -- ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -`
Expected: 差分なし（終了コード 0）

- [ ] **Step 2: `parent_note` を追加する**

`bin/git-stack.rb` の `print_tree_row` の直前（`# Print one tree row for ...` のコメントブロックの上）に追加する:

```ruby
# The note printed beside a branch whose recorded parent is not a normal tracked
# edge -- "" when it is one. This is the SINGLE home of these two sentences.
#
# `tree` used to own them inline, and `parent`/`down` said nothing at all: `down`
# checked out a branch `tree` never drew, and `parent` printed its name with no
# hint that the stack above it renders somewhere else (issue #85). They now print
# THIS, not a copy of it, so the two commands cannot drift into describing the
# same branch differently.
#
# The two cases are exclusive by construction, so the order of the tests below
# carries no meaning: `untracked_parent?` requires the parent's ref to EXIST,
# `parent_missing?` requires it not to.
def parent_note(branch, topology)
  parent = topology.parent_of(branch)
  return yellow("(parent '#{parent}' is untracked)") if topology.untracked_parent?(branch)
  return yellow("(parent '#{parent}' missing; run `#{PROG} sync`)") if topology.parent_missing?(branch)

  ""
end
```

- [ ] **Step 3: `print_tree_row` を `parent_note` 経由に書き換える**

`bin/git-stack.rb:1283-1312` の本体を丸ごと次に置き換える:

```ruby
def print_tree_row(branch, depth, cur, snapshot)
  extra = ""
  topology = snapshot.topology
  parent = topology.parent_of(branch)
  if !parent.empty? && topology.branch?(parent)
    # Counts from the batched `for-each-ref` (see scan_ahead_behind); the
    # sentinel guards the git-too-old case with a per-node fallback.
    behind, ahead = snapshot.ahead_behind_of(branch)
    if behind < 0
      behind, ahead = ahead_behind(parent, branch)
    end
    if behind > 0
      extra = yellow("(needs restack: #{behind} behind)")
    elsif ahead > 0
      extra = dim("(#{ahead} commit(s))")
    end
  end

  # An untracked parent is never drawn, so this row sits at root indent as if it
  # rested on the trunk. Name the parent it actually rests on -- silence here is
  # what made the whole subtree look like it belonged to the trunk. A parent
  # whose ref is gone gets the sync hint from the same place, which is what keeps
  # this row and `git stack parent` from saying different things (see parent_note).
  note = parent_note(branch, topology)
  unless note.empty?
    extra = extra.empty? ? note : "#{extra} #{note}"
  end

  puts "#{"  " * depth}#{tree_marker(branch, cur)} #{tree_name(branch, cur, "")} #{extra}"
  nil
end
```

置き換えが等価である根拠（レビュー時に確かめる点）:
- 旧 untracked 注記は `if !parent.empty? && branch?(parent)` の内側にあったが、`untracked_parent?` はその両方を内部で要求するので条件は同値。
- 旧 missing 注記は `elsif !parent.empty?`（＝ `!parent.empty? && !branch?(parent)`）にあり、これは `parent_missing?` の定義そのもの。
- 連結順（ahead/behind が先、注記が後）も同じ。

- [ ] **Step 4: スナップショットが変わっていないことを確認する**

Run: `mise x -- ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -`
Expected: 差分なし。**ここで差分が出たらリファクタが等価でない** ―― `.expected` を再生成せず、Step 3 の置き換えを見直すこと。

- [ ] **Step 5: RBS シードに `parent_note` と `untracked_parent?` のピンを足す**

`rbs/git-stack.rbs` の `class Object` ブロック、`def children_of:` の行の直後に追加:

```rbs
  def parent_note: (String, StackTopology) -> String
```

`class StackTopology` ブロックの `def parent_missing?:` の行の直後に追加:

```rbs
  def untracked_parent?: (String) -> bool
```

ピンの根拠をシード冒頭のコメント群の末尾（`# So: add a pin when a widening makes one necessary, ...` の段落の直前）に一段落として追加:

```
# `parent_note` and `untracked_parent?` are the issue #85 pair: the note `tree`
# prints is now also read by `parent`/`down`, so its branch-name parameter is
# unified across three call sites instead of one. That is exactly the shape the
# first four entries were written for, and both assertions are faithful -- a
# branch name and the topology it is asked about, String and StackTopology at
# every call site.
```

- [ ] **Step 6: 型チェックとコンパイル済みバイナリを通す**

Run:
```bash
spinel-doctor bin/git-stack.rb
spinel-doctor test/cli_test.rb
spin build && test/binary_test.sh | diff -u test/binary_test.sh.expected -
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && diff -u test/git-stack.rbs.expected /tmp/emitted.rbs
```
Expected: doctor は error-severity の指摘なし、binary_test は差分なし。emitted RBS に差分が出た場合は `untyped (slow path)` の行数を数える:
```bash
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && grep -c 'untyped (slow path)' /tmp/emitted.rbs
```
35 以下なら `spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=test/git-stack.rbs.expected` で再生成してよい。36 以上なら widening の起点を潰すまで進めない。

- [ ] **Step 7: コミット**

```bash
git add bin/git-stack.rb rbs/git-stack.rbs test/git-stack.rbs.expected
git commit -m "refactor: give tree's parent note one home to be read from

Two sentences that only tree could say. parent and down are about to say
the same ones, and a copy would be a copy that drifts. Behaviour is
unchanged -- the snapshot is byte-identical."
```
（`test/git-stack.rbs.expected` に差分がなければ `git add` から外す。）

---

### Task 2: `parent` / `down` が注記を出す（issue #85 の A）

**Files:**
- Modify: `bin/git-stack.rb:1406-1418`（`cmd_parent`）、`bin/git-stack.rb:1439-1447`（`cmd_down`）
- Test: `test/cli_test.rb`（セクション2つ追加）、`test/cli_test.rb.expected`（再生成）

**Interfaces:**
- Consumes: Task 1 の `parent_note(branch, topology) -> String`、既存の `StackRepository.load_topology(trunks) -> StackTopology`、`info(msg) -> nil`（**stderr** に書く）、`effective_parent(branch, trunks) -> String`
- Produces: なし（コマンドの出力だけ）

`effective_parent` は**触らない**。`feat-a` に降りる挙動はそのまま。

- [ ] **Step 1: 失敗するテストを書く（往復のセクション）**

`test/cli_test.rb` の末尾（`section "tree keeps a branch whose name collides with a tag"` のブロックの後ろ）に追加:

```ruby
# `tree` draws feat-b at trunk-child indent and names the untracked parent it
# actually rests on; `up`, `parent` and `down` all have to agree with it. The
# whole loop runs in ONE section on purpose -- the bug was a disagreement
# BETWEEN these commands, so only their outputs side by side in the transcript
# can show it (issue #85). Nothing else here would notice.
#
# `down` deliberately lands on feat-a, a branch tree never drew as a row: it is
# where `restack` replays feat-b onto, so refusing to go there would be its own
# kind of lie. The note is what makes the jump legible.
section "up and down round-trip through an untracked parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q main")
run("tree")
run("up")
show("HEAD", "git branch --show-current")
run("parent")
run("down")
show("HEAD", "git branch --show-current")
# feat-a records no parent of its own, so the walk down ends at the trunk
run("down")
show("HEAD", "git branch --show-current")
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `mise x -- ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -`
Expected: FAIL。追加したセクションぶんの差分が出て、その中で
`$ git stack up` が `error: no branch stacked on top of 'main'` / `[exit 1]` を出し、
`$ git stack parent` が `feat-a` **だけ**（注記なし）を出していること。これが issue の A と B そのもの。

- [ ] **Step 3: `cmd_parent` に注記を足す**

`bin/git-stack.rb:1406-1418` の `cmd_parent` を次に置き換える:

```ruby
def cmd_parent(args)
  branch = current_branch
  new_parent = arg0(args)
  trunks = trunk_branches
  if new_parent.empty?
    puts effective_parent(branch, trunks)
    # The name goes to stdout, where a script reads it; the note goes to stderr,
    # where a person does. Piping `git stack parent` still yields exactly the
    # branch name it always did.
    #
    # It is `tree`'s own sentence from `tree`'s own function (see parent_note),
    # so the two commands cannot answer this question differently. The topology
    # is loaded only on this read path -- setting a parent below has no note to
    # print and should not pay for one.
    note = parent_note(branch, StackRepository.load_topology(trunks))
    info note unless note.empty?
    return
  end
  die("cannot set parent of trunk '#{branch}'") if is_trunk?(branch, trunks)
  StackRepository.load_topology(trunks).validate_new_parent!(branch, new_parent, "setting it as parent")
  reparent!(branch, new_parent, "failed to set parent of '#{branch}'")
  info "parent of '#{branch}' set to '#{new_parent}'"
end
```

- [ ] **Step 4: `cmd_down` に注記を足す**

`bin/git-stack.rb:1439-1447` の `cmd_down` を次に置き換える:

```ruby
def cmd_down(_args)
  branch = current_branch
  trunks = trunk_branches
  parent = effective_parent(branch, trunks)
  # True for every trunk, and for a branch hand-configured as its own parent.
  die("already at the bottom of the stack") if parent == branch
  die("parent branch '#{parent}' no longer exists") unless branch_exists?(parent)
  # `down` walks to the branch `restack` actually replays onto, and that is not
  # always a branch `tree` drew a row for: an untracked parent is a real edge
  # with no row. Say so before moving HEAD somewhere the user has never seen
  # (issue #85). Only the untracked case reaches this line -- a parent whose ref
  # is gone already died above, with a message that says the same thing.
  note = parent_note(branch, StackRepository.load_topology(trunks))
  info note unless note.empty?
  checkout!(parent)
end
```

- [ ] **Step 5: `parent` が missing な親にも注記を出すことを確かめるテストを足す**

`test/cli_test.rb` の Step 1 で足したセクションの後ろに追加:

```ruby
# The other half of the same sentence-sharing: a parent whose ref is gone. `tree`
# has always printed the sync hint for it; `parent` printed the dead name with no
# hint at all. Both rows come from parent_note now, so they are the same words.
# `down` does not reach the note -- it dies on the missing ref first, saying the
# same thing in its own way -- and that is shown here rather than assumed.
section "parent notes a parent whose ref is gone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("tree")
run("parent")
run("down")
```

- [ ] **Step 6: スナップショットを再生成し、差分を目で読む**

Run:
```bash
mise x -- ruby test/cli_test.rb > test/cli_test.rb.expected
git diff test/cli_test.rb.expected
```
Expected: 差分は**追加したセクションだけ**。既存セクションの行が動いていたら意図しない挙動変更なので止めること。追加分の中で確認する点:
- `$ git stack parent` の出力が `feat-a` の行と `(parent 'feat-a' is untracked)` の行の2行になっている
- `$ git stack down` が注記のあと `Switched to branch 'feat-a'` になっている
- missing のセクションで `parent` が `(parent 'feat-a' missing; run \`git stack sync\`)` を出し、`down` は従来通り `error: parent branch 'feat-a' no longer exists` で `[exit 1]`
- `$ git stack up` はまだ `error: no branch stacked on top of 'main'`（Task 3 で直す）

- [ ] **Step 7: 型チェックとバイナリを通す**

Run:
```bash
spinel-doctor bin/git-stack.rb
spinel-doctor test/cli_test.rb
spin build && test/binary_test.sh | diff -u test/binary_test.sh.expected -
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && grep -c 'untyped (slow path)' /tmp/emitted.rbs
```
Expected: doctor は error なし、binary_test は差分なし、untyped は 35 以下。

- [ ] **Step 8: コミット**

```bash
git add bin/git-stack.rb test/cli_test.rb test/cli_test.rb.expected
git commit -m "fix: say which untracked parent down is walking to

parent printed a name tree draws nowhere and down checked it out, both
in silence. The name is right -- restack replays onto it -- so name it
rather than hide it, in tree's own words. stdout is unchanged; the note
goes to stderr, so scripts reading parent still read a branch name."
```

---

### Task 3: `up` が detached root を trunk の子として拾う（issue #85 の B）

**Files:**
- Modify: `bin/git-stack.rb:510-515`（トップレベル `children_of`）
- Modify: `rbs/git-stack.rbs`
- Test: `test/cli_test.rb`（セクション2つ追加）、`test/cli_test.rb.expected`（再生成）

**Interfaces:**
- Consumes: `StackRepository.load_topology(trunks) -> StackTopology`、`StackTopology#children_of(branch) -> Array[String]`、`StackTopology#detached_roots -> Array[String]`、`is_trunk?(branch, trunks) -> bool`、`containing_trunk(branch, trunks) -> String`（すべて既存）
- Produces: トップレベル `children_of(parent, trunks) -> Array[String]` ―― シグネチャは不変。`cmd_up` は無変更。

- [ ] **Step 1: 失敗するテストを書く（メニュー順と multi-trunk の帰属）**

`test/cli_test.rb` の Task 2 で足した2セクションの後ろに追加:

```ruby
# The "pick one" menu has to read in the same order as the tree above it:
# recorded children first, then the detached roots -- which is the order `tree`
# prints those same rows in. `other` is the trunk's tracked child, feat-b the
# detached root, and both are rows under main.
section "up lists a detached root alongside the trunk's tracked children"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q main")
gsq("create other"); commit("o.txt", "o1")
setup("git checkout -q main")
run("tree")
run("up")

# Trunks are peers, and `up` MOVES HEAD -- so a detached root belongs to the one
# trunk its history rests on, not to whichever trunk you happen to stand on.
# This is the same question #73 made `track`/`sync`/`drop` ask. `tree` draws the
# root without saying whose it is; `up` has to decide, and it decides by history.
section "up offers a detached root only from the trunk its stack rests on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
gsq("untrack")
run("tree")
setup("git checkout -q main")
run("up")
setup("git checkout -q develop")
run("up")
show("HEAD", "git branch --show-current")
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `mise x -- ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -`
Expected: FAIL。追加分で `$ git stack up` が
- 1つ目のセクションでは `other` に直行してしまう（feat-b がメニューに出ない）
- 2つ目のセクションでは develop からも `error: no branch stacked on top of 'develop'`

- [ ] **Step 3: `children_of` を拡張する**

`bin/git-stack.rb:510-515` を次に置き換える:

```ruby
# Every branch `up` can move to from `parent`: the rows `tree` draws directly
# under it. Builds a throwaway topology (one config scan, no ahead/behind walk)
# -- the one-shot path for `up`, distinct from the snapshot `tree` threads
# through rendering.
#
# For an ordinary branch that is exactly its recorded children. For a TRUNK it is
# those PLUS the detached roots: the stacks `tree` renders at trunk-child indent
# because nothing tracked reaches them -- a parent that was untracked while it
# still had children, or one that was merged and deleted. `tree` drew them there
# and `up` could not reach them, which is the contradiction issue #85 names; the
# rule now is one sentence, "up offers the rows tree draws under this branch".
#
# Trunks are peers, so a detached root belongs to the ONE trunk its history rests
# on -- `containing_trunk`, the same question `track` / `sync`'s orphan heal /
# `drop`'s reconnect each ask (issue #73). Without it `up` from `main` would
# offer a develop-based stack and then check it out, which is #73's mistake in a
# command that moves HEAD. It costs nothing in the single-trunk repo, where
# `containing_trunk` short-circuits before spending a `git`.
#
# No root can appear twice: `detached_roots` already drops any whose own parent
# is a trunk, and that is exactly the set `children_of` answers.
#
# Appended with `each` and `<<` rather than `+` or `concat`: nothing in this file
# concatenates arrays, and the array methods Spinel resolves only on a concrete
# receiver are the ones that compile clean and die on the shipped binary (see
# test/binary_test.sh). The list being appended to is freshly built by
# `StackTopology#children_of`, so mutating it here shares nothing.
def children_of(parent, trunks)
  topology = StackRepository.load_topology(trunks)
  children = topology.children_of(parent)
  return children unless is_trunk?(parent, trunks)

  topology.detached_roots.each do |root|
    children << root if containing_trunk(root, trunks) == parent
  end
  children
end
```

- [ ] **Step 4: スナップショットを再生成し、差分を目で読む**

Run:
```bash
mise x -- ruby test/cli_test.rb > test/cli_test.rb.expected
git diff test/cli_test.rb.expected
```
Expected: 変わるのは Step 1 で足した2セクションと、Task 2 で足した「往復」セクションの `$ git stack up` の行（`error: ...` → `Switched to branch 'feat-b'` と続く `HEAD: feat-b`）だけ。確認する点:
- 往復セクションで `main → feat-b → feat-a → main` が全部繋がっている
- メニューのセクションで `other` と `feat-b` がこの順に並んでいる
- multi-trunk のセクションで `main` の `up` は `error: no branch stacked on top of 'main'` のまま、`develop` の `up` が feat-b に移る
- **それ以外の既存セクションが1行も動いていない**（特に `up` を使う `section "down / up navigate the stack"` と `section "up with multiple children requires a choice"`）

- [ ] **Step 5: RBS シードに `detached_roots` のピンを足す**

`rbs/git-stack.rbs` の `class StackTopology` ブロック、`def children_of:` の行の直後に追加:

```rbs
  def detached_roots: () -> Array[String]
```

Task 1 で足したコメント段落の末尾に一文を継ぎ足す:

```
# `detached_roots` joins them for the third piece of the same change: `up` now
# reads it, so its hand-built `[]` is unified with the concrete children list it
# is appended to, and an `Array[untyped]` there would take `cmd_up`'s `include?`
# / `length` / `[0]` down with it.
```

- [ ] **Step 6: 型チェックとバイナリを通す**

Run:
```bash
spinel-doctor bin/git-stack.rb
spinel-doctor test/cli_test.rb
spin build && test/binary_test.sh | diff -u test/binary_test.sh.expected -
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && grep -c 'untyped (slow path)' /tmp/emitted.rbs
```
Expected: doctor は error なし、binary_test は差分なし、untyped は 35 以下。

このタスクは新しい配列を組み立てるので、**ここが binary_test の一番効く場所**。`spin test` と CRuby スナップショットが両方通ってもバイナリだけが落ちる形があり得るので、必ず `spin build` まで走らせること。emitted RBS に差分が出て untyped が 35 以下なら再生成:
```bash
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=test/git-stack.rbs.expected
```

- [ ] **Step 7: コミット**

```bash
git add bin/git-stack.rb rbs/git-stack.rbs test/cli_test.rb test/cli_test.rb.expected
git commit -m "fix: let up reach the rows tree draws under a trunk

tree renders a detached root at trunk-child indent and up answered that
nothing was stacked there -- the same tree row, two commands, opposite
answers. up now offers those roots, each from the one trunk its history
rests on rather than from whichever trunk you stand on."
```

---

### Task 4: バイナリ fixture と仕上げ

**Files:**
- Modify: `test/binary_test.sh`（必要なら）、`test/binary_test.sh.expected`（必要なら）

**Interfaces:**
- Consumes: Task 3 の `children_of`
- Produces: なし

- [ ] **Step 1: バイナリ fixture が新しい経路を歩いているか確認する**

Run: `grep -n "up\|untrack" test/binary_test.sh`
Expected: fixture が trunk 上で `up` を叩き、かつ detached root がある形になっているか読む。

- [ ] **Step 2: 歩いていなければ fixture に一行足す**

`test/binary_test.sh` の既存の orphan fixture のあとに、trunk 上からの `up` を追加する（既存のスクリプトの書き方に合わせること）。detached root がある状態で trunk から `up` を叩くのが目的 ―― Task 3 の `each`/`<<` と `containing_trunk` のループが**コンパイル済みバイナリ上で**一度も実行されないまま緑になるのを防ぐ。

Step 1 で既に歩いていると確認できたなら、このステップは飛ばして Step 3 へ。

- [ ] **Step 3: バイナリ fixture のスナップショットを再生成して差分を読む**

Run:
```bash
spin build
test/binary_test.sh > test/binary_test.sh.expected
git diff test/binary_test.sh.expected
```
Expected: 差分は追加した行ぶんだけ。`NoMethodError` がどこにも出ていないこと。

- [ ] **Step 4: 全部の検証をまとめて通す**

Run:
```bash
mise x -- ruby test/cli_test.rb | diff -u test/cli_test.rb.expected -
spinel-doctor bin/git-stack.rb
spinel-doctor test/cli_test.rb
spin test
spin build && test/binary_test.sh | diff -u test/binary_test.sh.expected -
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && diff -u test/git-stack.rbs.expected /tmp/emitted.rbs
spinel --emit-rbs --rbs rbs/ bin/git-stack.rb --output=/tmp/emitted.rbs && grep -c 'untyped (slow path)' /tmp/emitted.rbs
```
Expected: すべて差分なし・error なし、untyped は 35 以下。

- [ ] **Step 5: コミット（差分があれば）**

```bash
git add test/binary_test.sh test/binary_test.sh.expected
git commit -m "test: walk up's new trunk path on the shipped binary

The children list up builds is assembled at run time, and an array
method Spinel cannot service there compiles clean and passes both
snapshots. Only the fixture binary can fail on it."
```

Step 1 で fixture が既に十分だった場合はコミットするものがない。その旨を報告して次へ。

---

## Self-Review

**Spec coverage:**

| spec のセクション | 対応タスク |
|---|---|
| 1. 注記の文言を1箇所にする（`parent_note`、既存述語の再利用） | Task 1 |
| 2. A: `down`/`parent` に注記（`effective_parent` 不変、stdout 不変、stderr へ、設定側は対象外） | Task 2 |
| 3. B: `up` が detached root を拾う（全 detached_roots、tree の描画順、重複なし、`up <name>` も通る） | Task 3 |
| 3. multi-trunk を `containing_trunk` で割り当て | Task 3 Step 1/3 |
| 4. テスト: 往復 / tree と parent の並置 / missing / multi-trunk | Task 2 Step 1・5、Task 3 Step 1 |
| 4. 通すべき CI（CRuby / spin test / binary / RBS ゴールデン） | 各タスクの型チェックステップ、Task 4 Step 4 |
| スコープ外（tree の描画、restack/sync、effective_parent/climb_to_root） | どのタスクでも触っていない |

**Placeholder scan:** 「適切にエラー処理」「同 Task N」「後で書く」の類はなし。Task 4 Step 2 だけは既存スクリプトを読んでからでないと確定できない形で書いてあるが、判断基準（detached root がある状態で trunk から `up`）と、不要と分かったときの分岐を明示してある。

**Type consistency:** `parent_note(branch, topology) -> String` は Task 1 で定義し、Task 2 の `cmd_parent`/`cmd_down` が同じ名前・同じ引数順で呼んでいる。トップレベル `children_of(parent, trunks) -> Array[String]` はシグネチャ不変で、`rbs/git-stack.rbs` の既存ピンと一致している。`StackTopology#untracked_parent?` / `#parent_missing?` / `#detached_roots` / `#children_of` / `#parent_of` はすべて既存メソッドで、名前を変えていない。

**`up <name>` の経路:** `cmd_up` は同じ `children_of` の結果に対して `include?` を取るので、detached root の名指しも自動的に通る。専用のタスクは要らない。
