# dft viewer

The viewer is a Tern plugin block (`dft-viewer.diff`) that shows a jj or git diff as difftastic
aligns it. `dft --tab <args>` opens it in a tab, one per calling pane, reused on the next call.

## Seen and reviewed

A hunk is a run of aligned rows where either side changed. Each hunk is unseen, seen or reviewed,
and the dock counts all three.

- **Seen**: the hunk under the cursor becomes seen after 1 s with no key pressed. Tern doesn't tell
  a block what the wheel scrolled to, so hunks scrolled past without the cursor stay unseen.
- **Reviewed**: `R` toggles the hunk at the cursor, `r` every hunk of the file.
- A mark is keyed by the hunk's new path and lines (not line numbers), so it survives `jj rebase`,
  `squash` and `describe`. A changed line makes the hunk unseen again. `u` hides marked hunks.
- Marks are kept per repository root in the plugin's key/value store.

## Search

- `/` searches with `rg` (Rust regex syntax) over both whole sides of every file that shows rows,
  folded code included. Binary and oversized files, and files difftastic calls unchanged, are not
  searched.
- Tab in the prompt cycles the sides: both, new, old.
- Smart case. `\c` forces case-insensitive and `\C` case-sensitive. `\V` at the start makes the
  pattern literal. A pattern `rg` can't parse (`loop {`) is searched literally, and the dock says so.
- The dock shows the count as `3/17`. A fold row says how many hits it holds; `n`/`N` to such a hit
  unfolds 3 lines around it. A hit in a collapsed file expands it, and a hit in a hunk hidden by `u`
  shows that hunk.

## Blame

Once the diff has loaded, the dock's second line shows who last changed the cursor's line: the
change or commit id, author, date and first line of the description. A row with a new-side line is
blamed at the diff's new revision, an old-only row at its old revision (`jj file annotate` or
`git blame`). Lines of the working tree or index say `not committed yet`.

## Drawing

- Unchanged code is folded to 3 lines around each change. `space` opens a fold.
- A diff over 1,500 rows is split into pages between files; a longer file gets its own pages. A
  page's first and last rows link to the previous and next page. The dock says `page 2/5`.
- Long lines are clipped. Each code column scrolls sideways on its own with a trackpad swipe or
  shift-wheel; the keys move every code column together. The dock says `from column 41`.
- `v` shows the file at the cursor unified (old line above new) or side by side; `V` does it for
  every file, and new viewers remember it.
- Enter opens the file at the cursor's line: the working-copy file when it matches the diff's new
  side, else that side's snapshot.

## Keys

| Keys | Action |
| --- | --- |
| `j` `k` `↓` `↑` | cursor down, up |
| `ctrl-d` `ctrl-u`, `ctrl-f` `ctrl-b`, `page_down` `page_up` | half screen, screen |
| `ctrl-e` `ctrl-y` | scroll one line |
| `g` `G` | top, bottom |
| `]` `[` | next, previous hunk, across files |
| `}` `{` | next, previous file |
| `>` `<` | next, previous page |
| `/` `n` `N` `Esc` | search, next, previous, clear |
| `space` | unfold at the cursor; on a file header, collapse or expand the file |
| `o` `O` | expand every file; collapse every file and fold unchanged code again |
| `R` `r` | reviewed: hunk, file |
| `u` | unmarked hunks only |
| `h` `l` `←` `→` | every code column sideways by 4 columns |
| `H` `L` `⇧←` `⇧→` | every code column sideways by half a column |
| `0` `$` | sideways: to the start, to the end of the cursor's line |
| swipe, shift-wheel | the code column under the pointer sideways |
| `v` `V` | unified or side by side: this file, every file |
| Enter | open the file at this line |
| click | put the cursor on the row; on a page's edge row, change page |
| `?` `q` | help, close the pane |
