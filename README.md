# tern-difftastic

A [Tern](https://docs.stencil.so/tern/) plugin that shows [difftastic](https://github.com/Wilfred/difftastic)'s
structural diffs of jj and git changes in a block, for reviewing. Removed lines are on the left and
added lines on the right, aligned the way difftastic aligns them, with the tokens it found changed
highlighted and Tern's own syntax colors underneath. Search covers both whole sides of every file,
and every hunk is unseen, seen or reviewed, keyed by its content so the marks survive `jj rebase`.

## Requirements

`difft` (`brew install difftastic`), `bun`, `rg`, and `jj` or `git`.

## Install

```sh
tern plugin install github.com/MicroProofs/tern-difftastic
ln -s "$(tern plugin dir)/dft-viewer/bin/dft" ~/.local/bin/dft
```

Plugins are trusted code with full access to your user account, so read `host.luau` and `bin/dft`
first, or pin a commit you have reviewed. To update, run the install again with `--force`.

To work on it, clone the repository and link it instead; Tern reloads it on every save:

```sh
git clone https://github.com/MicroProofs/tern-difftastic
tern plugin link tern-difftastic
ln -s "$PWD/tern-difftastic/bin/dft" ~/.local/bin/dft
```

## Use

In a jj repository (colocated ones included) `dft` takes `jj diff` arguments; in a git repository,
`git diff` arguments. `DFT_VCS=git|jj` overrides the detection.

```sh
dft --tab                         # jj: the working-copy change; git: working tree vs HEAD + untracked
dft --tab -r xyz                  # jj: one revision
dft --tab -r 'trunk()..@'         # jj: a range, as one combined diff
dft --tab --from main --to @      # jj: any two revisions
dft --tab main...HEAD             # git: anything `git diff` takes (--staged, -- path, …)
```

`dft --tab` opens the viewer in a new tab, and the next `dft --tab` from the same pane reuses it.
Without `--tab`, `dft` prints difftastic's own colored diff. Press `?` in the viewer for its keys;
[SPEC.md](SPEC.md) describes them and what the viewer shows.

### jjui

This action binds `d` in jjui's revision list to the viewer: the highlighted revision, or with
revisions checked (space) everything from the earliest to the latest of them. `jj_async` keeps jjui
running behind the viewer's tab.

```toml
# ~/.config/jjui/config.toml
[[actions]]
name = "dft"
lua = """
  local ids = context.checked_change_ids()
  local rev
  if #ids > 1 then
    local set = table.concat(ids, "|")
    rev = "roots(" .. set .. ")::heads(" .. set .. ")"
  elseif #ids == 1 then
    rev = ids[1]
  else
    rev = context.change_id()
  end
  jj_async("util", "exec", "--", "dft", "--tab", "-r", rev)
"""

[[bindings]]
key = ["d"]
action = "dft"
scope = "revisions"
desc = "diff with difftastic (dft)"
```

## difftastic settings

Each is an environment variable read by `dft`:

| Variable | dft default | difftastic default |
|---|---|---|
| `DFT_BYTE_LIMIT` | 2 MiB | 1 MB |
| `DFT_PARSE_ERROR_LIMIT` | 4 | 0 |
| `DFT_GRAPH_LIMIT` | 3,000,000 | 3,000,000 |
| `DFT_RETRY_GRAPH_LIMIT` | 30,000,000: a file over `DFT_GRAPH_LIMIT` is tried again with this | none |
| `DFT_RETRY_SECONDS` | 20: the retry gives up after this and keeps the line diff | none |
| `DFT_OVERRIDES` | `*.uplc:Clojure,*.snap:text` (comma-separated `glob:language`) | none |

## Limits

- difftastic's JSON output is marked unstable. If its shape changes, a file shows "difftastic's
  JSON was not recognized" instead of a wrong diff.
- Files over 2 MiB per side, binary files and files that aren't UTF-8 are listed with a note.
- jj hands `dft` folders, not rename information, so a renamed file shows as a deletion plus an
  addition.
- git: untracked files are included only when `dft` gets no arguments.

## License

MIT, see [LICENSE](LICENSE).
