--!strict
-- Block `dft-viewer.diff`: a jj or git diff as difftastic aligns it, for
-- reviewing. Spec: SPEC.md. The block runs `dft --emit DIR <args>` and reads
-- one record per file from DIR as dft writes them; texts stay in DIR and are
-- read when rows need them.
--
-- Every row of the cursor's page is drawn, so the wheel scrolls natively; a
-- diff past PAGE_ROWS is split into pages (see reindex), changed with the
-- edge rows, `>`/`<`, or any jump that leaves the page. Row keys are stable
-- (see rowKey: f<file>h, f<file>p<pair>, …).
--
-- Reads top-down: constants and types, file models, texts and marks, row
-- layout, drawing, navigation, search, loading, then the block itself.

local ui = tern.ui

-- Rows per page: every row of a page is drawn at once.
local PAGE_ROWS = 1500
-- Dock lines (status, prompt), each one terminal line high (viewer.css).
local DOCK_ROWS = 2
-- Loading: a tick every TICK_MS reads records for up to SLICE_MS.
local TICK_MS = 30
local SLICE_MS = 25
-- While loading, the view is redrawn at most this often.
local RENDER_EVERY_MS = 150
-- The hunk under the cursor counts as seen after this long with no key pressed.
local SEEN_MS = 1000
-- The search reruns this long after typing stops.
local SEARCH_DELAY_MS = 150
-- The request file is checked (and the heartbeat written) this often.
local REQUEST_POLL_MS = 250
-- Texts kept split into lines (estimated bytes).
local TEXT_CACHE = 48 * 1024 * 1024
-- Past this VM size (KB), files still to load are listed but not modeled.
local MEMORY_STOP_KB = 176 * 1024
-- Cached row nodes before the cache is dropped.
local NODE_CACHE = 4000
-- Matches kept for highlighting and n/N; past this the count still runs.
local MAX_HITS = 100000
-- Sideways by keys: h/l move HSTEP columns (H/L half a code column, 0/$ the start and the end),
-- both sides together; a swipe scrolls one code column natively on top of that.
local HSTEP = 4
-- Unchanged pairs shown on each side of a change.
local CONTEXT = 3

-- Row kinds (Layout.kind).
local HEAD = 1
local PAIR = 2
local FOLD = 3
local MARKED = 4
local NOTE = 5

local HOME = tern.getenv("HOME") or ""
-- `dft --emit` folders, one per load.
local EMIT_ROOT = tern.plugin.data .. "/emit"
-- The daemon's PATH may lack the user's tools; dft needs jj or git, difft and bun.
local PATH = table.concat({ "/opt/homebrew/bin", HOME .. "/.local/bin", HOME .. "/.bun/bin", HOME .. "/.cargo/bin", "/usr/local/bin", "/usr/bin", "/bin" }, ":")
	.. ":"
	.. (tern.getenv("PATH") or "")

local function which(name: string, candidates: { string }): string
	for _, c in candidates do
		if tern.fs.exists(c) then
			return c
		end
	end
	return name
end

local BUN = which("bun", { HOME .. "/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun" })
local RG = which("rg", { "/opt/homebrew/bin/rg", "/usr/local/bin/rg", HOME .. "/.cargo/bin/rg" })
-- bin/dft in this plugin's folder, else the one installed on PATH.
local DFT = which("dft", { tern.plugin.dir .. "/bin/dft", HOME .. "/.local/bin/dft" })

---------------------------------------------------------------------------
-- Types

-- File models: one per `dft --emit` record. A model keeps difftastic's row
-- alignment and novel tokens in compact form; the texts stay on disk (the
-- emit folder) and are read through readLines when a row needs them.

-- One novel token run on a line: 0-based byte offsets [s, e) and difftastic's highlight kind.
type Change = { s: number, e: number, hl: string }
-- 1-based line -> its novel runs, sorted, merged and non-overlapping.
type Novel = { [number]: { Change } }

-- A maximal run of aligned rows where either side changed.
type Hunk = {
	first: number,
	last: number,
	-- Content key: survives rewrites that keep the hunk's lines (see addFile).
	key: string,
}

type File = {
	-- Position in the diff, 1-based; row keys are built from it.
	id: number,
	path: string,
	oldPath: string?,
	added: boolean,
	deleted: boolean,
	modes: string?,
	language: string?,
	-- Why the file has no rows (binary, too large, formatting only, …).
	note: string?,
	hasOld: boolean,
	hasNew: boolean,
	-- Aligned rows: per row the 1-based old and new line, 0 for none (u32 each).
	n: number,
	pl: buffer,
	pr: buffer,
	-- Per row: 1 when the old side changed, 2 when the new side did (u8, or-ed).
	chg: buffer,
	novelL: Novel,
	novelR: Novel,
	hunks: { Hunk },
	added_rows: number,
	removed_rows: number,
	-- Lines of each side, for line-number widths.
	oldLines: number,
	newLines: number,
}

-- Display rows. Each file lays out its own rows (header, aligned pairs, folds
-- of unchanged pairs, hidden marked hunks, a note); the diff's rows are the
-- files' rows end to end, found through `starts` by binary search. Changing
-- one file's folds relays only that file.
type Layout = {
	file: File,
	collapsed: boolean,
	-- Unified: a changed pair takes a row per side (old, then new), an unchanged pair one row.
	unified: boolean,
	-- Pairs forced visible (unfolded folds, context around search hits): u8 per pair, created on first use.
	force: buffer?,
	-- Hunks (by index) shown even when marked and hiding marked hunks.
	shown: { [number]: boolean },
	-- Rows: kind; `a` = the pair the row stands at (0 for header and note), `b` = fold end or hunk index;
	-- for a pair, the side it shows: 0 both, 1 old only, 2 new only (unified rows of a changed pair).
	kind: { number },
	a: { number },
	b: { number },
}

-- What decides whether a marked hunk is hidden.
type Hide = (f: File, hunk: number) -> boolean

-- Hunk marks per repository: hunk key -> "s" (seen, automatic) or "r"
-- (reviewed, explicit). Kept in <plugin data>/marks/<hash of root>.json. A
-- save rereads the file and applies only the keys this pane changed, so two
-- panes on one repository keep each other's marks.
type Marks = {
	path: string,
	root: string,
	map: { [string]: string },
	-- Keys this pane changed since the last save.
	changed: { [string]: boolean },
	dirty: boolean,
}

-- The texts the pane shows, read from the emit folder (`<dir>/old/<path>`,
-- `<dir>/new/<path>`) and split into lines on demand. Kept in a cache bounded
-- by an estimate of the memory the split lines take, least recently used first
-- out; models don't hold texts, so a large range never holds all of them.
type TextCache = {
	entries: { [string]: { lines: { string }, cost: number, used: number } },
	cost: number,
	clock: number,
}

-- Search: `rg` over the texts the pane shows (the emit folder's old/ and new/
-- trees), so the pattern syntax, case rules and match counts are ripgrep's.
-- Output is one line per match (`--only-matching --column`); it is parsed in
-- slices across timer ticks, then ordered as the rows show them.
type Query = {
	text: string,
	-- "both", "new" or "old".
	sides: string,
	-- Searched literally because rg couldn't parse the pattern as a regex.
	fellBack: boolean?,
}

type Hits = {
	query: Query,
	-- Per match: file id, side (1 old, 2 new), 1-based line, 0-based byte range [s, e), aligned pair.
	f: { number },
	side: { number },
	line: { number },
	s: { number },
	e: { number },
	pair: { number },
	-- Matches found (may exceed #f when capped).
	total: number,
	-- byLine[file id][side][line] = hit indices on that line, in order.
	byLine: { [number]: { [number]: { [number]: { number } } } },
	-- Sorted pairs of each file's hits, for counting hits inside folds.
	pairs: { [number]: { number } },
}

-- Line -> aligned pair, per file and side, built when a search first needs it.
type PairIndex = { [number]: { [number]: buffer } }

type Parser = {
	out: string,
	pos: number,
	hits: Hits,
	-- "old/<path>" and "new/<path>" -> file and side.
	paths: { [string]: { f: File, side: number } },
}

-- `block`: the viewer the request is for (set when dft found one open); nil for a new viewer.
type Request = { cwd: string, args: { string }, seq: number, block: number? }

type Prompt = { text: string, sides: string, cur: number }

type SearchState = {
	hits: Hits?,
	-- Current hit (index into hits), 0 for none; `at` is the cursor row it put the cursor on.
	cur: number,
	at: number,
	-- Bumped per search started; stale results are dropped.
	seq: number,
	text: string,
	sides: string,
	error: string?,
	-- Enter closed the prompt: the cursor goes to the first hit after `from` once the hits arrive.
	jump: boolean,
	from: number,
	-- Bumped each time a result is published: row signatures name the hits they drew.
	gen: number,
}

type CacheEntry = { sig: string, nodes: { Node }, lines: { string }? }

type State = {
	cx: BlockCx,
	pane: number,
	reqPath: string?,
	req: Request?,
	-- Bumped per load; callbacks of an older load stop.
	run: number,
	dir: string?,
	root: string?,
	layouts: { Layout },
	starts: { number },
	total: number,
	-- First global row of each page.
	pages: { number },
	nextRec: number,
	loading: boolean,
	failed: string?,
	messages: string?,
	leftOut: number,
	cur: number,
	hx: number,
	-- Files lay out unified (V; v flips one file); new files take this.
	unified: boolean,
	since: boolean,
	marks: Marks?,
	texts: TextCache,
	pairIndex: PairIndex,
	search: SearchState,
	prompt: Prompt?,
	help: boolean,
	cache: { [string]: CacheEntry },
	cached: number,
	-- The pending "seen" timer: any key or event cancels it.
	seen: TimerHandle?,
	lastRender: number,
	renderDue: boolean,
	saveDue: boolean,
	t0: number,
	firstFrame: boolean,
	firstRows: boolean,
	peak: number,
	maxLine: number,
	message: string?,
	dead: boolean,
}

local live: { [number]: State } = {}
local watching = false

local function metric(ev: string, fields: { [string]: any })
	fields.ev = ev
	tern.log.info("dftv " .. tern.json.encode(fields))
end

local function memKB(s: State): number
	local kb = gcinfo()
	if kb > s.peak then
		s.peak = kb
	end
	return kb
end

local function height(cx: BlockCx): number
	return math.max(3, cx.rows - DOCK_ROWS - 1)
end

local function readJson(path: string): any
	local ok, value = pcall(function(): any
		return tern.json.decode(tern.fs.read(path))
	end)
	return if ok then value else nil
end

---------------------------------------------------------------------------
-- File models

local function oldAt(f: File, i: number): number
	return buffer.readu32(f.pl, (i - 1) * 4)
end

local function newAt(f: File, i: number): number
	return buffer.readu32(f.pr, (i - 1) * 4)
end

local function chgAt(f: File, i: number): number
	return buffer.readu8(f.chg, i - 1)
end

-- The index of the hunk holding row `i`, or nil.
local function hunkAt(f: File, i: number): number?
	local lo, hi = 1, #f.hunks
	while lo <= hi do
		local mid = (lo + hi) // 2
		local h = f.hunks[mid]
		if i < h.first then
			hi = mid - 1
		elseif i > h.last then
			lo = mid + 1
		else
			return mid
		end
	end
	return nil
end

-- Two 32-bit hashes (FNV-1a and djb2) of `text`, as 16 hex digits. Exact in
-- doubles: FNV's prime is 2^24 + 403, so h * prime = h * 403 + (h << 24).
local function hash(text: string): string
	local h1, h2 = 2166136261, 5381
	local byte, bxor, lshift = string.byte, bit32.bxor, bit32.lshift
	for i = 1, #text do
		local c = byte(text, i)
		h1 = bxor(h1, c)
		h1 = (h1 * 403 + lshift(h1, 24)) % 4294967296
		h2 = (h2 * 33 + c) % 4294967296
	end
	return string.format("%08x%08x", h1, h2)
end

-- Novel runs of one side, merged so that every byte belongs to at most one run.
local function novelOf(chunks: any, side: string): Novel
	local out: Novel = {}
	if type(chunks) ~= "table" then
		return out
	end
	for _, chunk in chunks do
		if type(chunk) ~= "table" then
			continue
		end
		for _, entry in chunk do
			local s = if type(entry) == "table" then entry[side] else nil
			if type(s) == "table" and type(s.line_number) == "number" and type(s.changes) == "table" then
				local line = s.line_number + 1
				local list = out[line] or {}
				for _, c in s.changes do
					if type(c) == "table" and type(c.start) == "number" and type(c["end"]) == "number" and c["end"] > c.start then
						local hl = string.gsub(tostring(c.highlight or "normal"), "[^%w_-]", "")
						table.insert(list, { s = c.start, e = c["end"], hl = hl })
					end
				end
				out[line] = list
			end
		end
	end
	for line, list in out do
		table.sort(list, function(a: Change, b: Change): boolean
			return a.s < b.s
		end)
		local merged: { Change } = {}
		for _, c in list do
			local last = merged[#merged]
			if last and c.s <= last.e and c.hl == last.hl then
				last.e = math.max(last.e, c.e)
			elseif last and c.s < last.e then
				-- Overlapping runs of different kinds: the first keeps the overlap.
				if c.e > last.e then
					table.insert(merged, { s = last.e, e = c.e, hl = c.hl })
				end
			else
				table.insert(merged, c)
			end
		end
		out[line] = if #merged > 0 then merged else nil
	end
	return out
end

-- Every line of one side, alone on its row (a created or deleted file).
local function oneSided(f: File, count: number, side: string)
	f.n = count
	f.pl = buffer.create(count * 4)
	f.pr = buffer.create(count * 4)
	f.chg = buffer.create(count)
	for i = 1, count do
		if side == "l" then
			buffer.writeu32(f.pl, (i - 1) * 4, i)
			buffer.writeu8(f.chg, i - 1, 1)
		else
			buffer.writeu32(f.pr, (i - 1) * 4, i)
			buffer.writeu8(f.chg, i - 1, 2)
		end
	end
	if side == "l" then
		f.removed_rows = count
	else
		f.added_rows = count
	end
end

-- The model of record `rec`, the `id`th file of the diff. Early returns
-- leave a file with a note and no rows.
local function fromRecord(id: number, rec: any): File
	local modes: string? = nil
	if type(rec.old_mode) == "string" then
		modes = string.format("mode %s → %s", rec.old_mode, tostring(rec.new_mode))
	end
	local d = rec.difft
	local f: File = {
		id = id,
		path = if type(rec.path) == "string" then rec.path else "?",
		oldPath = if type(rec.old_path) == "string" then rec.old_path else nil,
		added = rec.added == true,
		deleted = rec.deleted == true,
		modes = modes,
		language = if type(d) == "table" and type(d.language) == "string" then d.language else nil,
		note = if type(rec.note) == "string" then rec.note else nil,
		hasOld = rec.has_old == true,
		hasNew = rec.has_new == true,
		n = 0,
		pl = buffer.create(0),
		pr = buffer.create(0),
		chg = buffer.create(0),
		novelL = {},
		novelR = {},
		hunks = {},
		added_rows = 0,
		removed_rows = 0,
		oldLines = if type(rec.old_lines) == "number" then rec.old_lines else 0,
		newLines = if type(rec.new_lines) == "number" then rec.new_lines else 0,
	}
	if f.note then
		return f
	end
	if f.added or (type(d) == "table" and d.status == "created") then
		if not f.hasNew or f.newLines == 0 then
			f.note = "empty file"
			return f
		end
		oneSided(f, f.newLines, "r")
	elseif f.deleted or (type(d) == "table" and d.status == "deleted") then
		if not f.hasOld or f.oldLines == 0 then
			f.note = "empty file"
			return f
		end
		oneSided(f, f.oldLines, "l")
	elseif type(d) ~= "table" or type(d.status) ~= "string" then
		f.note = "difftastic's JSON was not recognized"
		return f
	elseif d.status == "changed" and type(d.aligned_lines) == "table" then
		-- difftastic aligns one line past the end of a file that ends in a
		-- newline (the empty "line" after it). That line doesn't exist: the
		-- side is dropped from the pair, and a pair left with no side is dropped.
		local kept: { { number } } = {}
		for _, p in d.aligned_lines do
			local l = if type(p[1]) == "number" and p[1] < f.oldLines then p[1] + 1 else 0
			local r = if type(p[2]) == "number" and p[2] < f.newLines then p[2] + 1 else 0
			if l > 0 or r > 0 then
				table.insert(kept, { l, r })
			end
		end
		local n = #kept
		f.n = n
		f.pl = buffer.create(n * 4)
		f.pr = buffer.create(n * 4)
		f.chg = buffer.create(n)
		f.novelL = novelOf(d.chunks, "lhs")
		f.novelR = novelOf(d.chunks, "rhs")
		local added, removed = 0, 0
		for i, p in kept do
			local l, r = p[1], p[2]
			buffer.writeu32(f.pl, (i - 1) * 4, l)
			buffer.writeu32(f.pr, (i - 1) * 4, r)
			local c = 0
			if l > 0 and (r == 0 or f.novelL[l] ~= nil) then
				c += 1
				removed += 1
			end
			if r > 0 and (l == 0 or f.novelR[r] ~= nil) then
				c += 2
				added += 1
			end
			buffer.writeu8(f.chg, i - 1, c)
		end
		f.added_rows, f.removed_rows = added, removed
	else
		f.note = if d.status == "unchanged" and (f.modes or f.oldPath) then "contents unchanged" else "no structural changes (formatting only)"
		return f
	end
	-- Hunk boundaries (their keys come later, from the texts).
	local i = 1
	while i <= f.n do
		if chgAt(f, i) ~= 0 then
			local j = i
			while j + 1 <= f.n and buffer.readu8(f.chg, j) ~= 0 do
				j += 1
			end
			table.insert(f.hunks, { first = i, last = j, key = "" })
			i = j + 1
		else
			i += 1
		end
	end
	if #f.hunks == 0 then
		f.note = "no structural changes (formatting only)"
		f.n = 0
	end
	return f
end

---------------------------------------------------------------------------
-- Texts and marks

local function sidePath(s: State, f: File, side: number): string
	if side == 1 then
		return (s.dir or "") .. "/old/" .. (f.oldPath or f.path)
	end
	return (s.dir or "") .. "/new/" .. f.path
end

-- The lines of `path` (absolute), or an empty list when it can't be read.
local function readLines(c: TextCache, path: string): { string }
	c.clock += 1
	local hit = c.entries[path]
	if hit then
		hit.used = c.clock
		return hit.lines
	end
	local ok, text = pcall(function(): string
		return tern.fs.read(path)
	end)
	-- Lines as dft counts them: a final newline ends the last line.
	local lines: { string } = {}
	if ok and type(text) == "string" then
		lines = string.split(text, "\n")
		if lines[#lines] == "" then
			table.remove(lines)
		end
	end
	-- A line string costs its bytes plus ~40 bytes of header and slot.
	local cost = (if ok and type(text) == "string" then #text else 0) + 40 * #lines
	c.entries[path] = { lines = lines, cost = cost, used = c.clock }
	c.cost += cost
	while c.cost > TEXT_CACHE do
		local oldest: string? = nil
		local at = math.huge
		for k, e in c.entries do
			if e.used < at then
				oldest, at = k, e.used
			end
		end
		if oldest == nil then
			break
		end
		c.cost -= c.entries[oldest].cost
		c.entries[oldest] = nil
	end
	return lines
end

local function lineText(s: State, f: File, side: number, line: number): string
	local lines = readLines(s.texts, sidePath(s, f, side))
	return lines[line] or ""
end

local function readMarks(path: string): { [string]: string }
	local data = readJson(path)
	local out: { [string]: string } = {}
	if type(data) == "table" and type(data.marks) == "table" then
		for k, v in data.marks do
			if type(k) == "string" and (v == "s" or v == "r") then
				out[k] = v
			end
		end
	end
	return out
end

local function saveMarks(s: State)
	local m = s.marks
	if m == nil or not m.dirty then
		return
	end
	local disk = readMarks(m.path)
	for k in m.changed do
		disk[k] = m.map[k]
	end
	tern.fs.mkdir(tern.plugin.data .. "/marks")
	tern.fs.write(m.path, tern.json.encode({ root = m.root, marks = disk }))
	m.map = disk
	m.changed = {}
	m.dirty = false
end

local function markOf(s: State, key: string): string?
	local m = s.marks
	return if m then m.map[key] else nil
end

-- Sets the mark of hunk `h` of `f` ("s", "r" or nil) and saves the marks a second later.
local function markHunk(s: State, f: File, h: number, value: string?)
	local m = s.marks
	if m == nil then
		return
	end
	local key = f.hunks[h].key
	if m.map[key] ~= value then
		m.map[key] = value
		m.changed[key] = true
		m.dirty = true
	end
	if not s.saveDue then
		s.saveDue = true
		tern.timer(1000, function()
			s.saveDue = false
			saveMarks(s)
		end)
	end
end

---------------------------------------------------------------------------
-- Rows

local function hideFn(s: State): Hide?
	if not s.since then
		return nil
	end
	return function(f: File, h: number): boolean
		return markOf(s, f.hunks[h].key) ~= nil
	end
end

local function forcePairs(l: Layout, from: number, to: number)
	local f = l.file
	if f.n == 0 then
		return
	end
	local force: buffer = l.force or buffer.create(f.n)
	l.force = force
	for i = math.max(1, from), math.min(f.n, to) do
		buffer.writeu8(force, i - 1, 1)
	end
end

-- Lays out the rows of one file.
local function layout(l: Layout, hide: Hide?)
	local f = l.file
	local kind, a, b = {}, {}, {}
	local function push(k: number, x: number, y: number)
		table.insert(kind, k)
		table.insert(a, x)
		table.insert(b, y)
	end
	push(HEAD, 0, 0)
	if l.collapsed then
		l.kind, l.a, l.b = kind, a, b
		return
	end
	if f.note ~= nil or f.n == 0 then
		push(NOTE, 0, 0)
		l.kind, l.a, l.b = kind, a, b
		return
	end
	local n = f.n
	local show = buffer.create(n)
	-- hiddenAt[first pair] = hunk index, for marked hunks folded into one row.
	local hiddenAt: { [number]: number } = {}
	for h, hunk in f.hunks do
		if hide and not l.shown[h] and hide(f, h) then
			hiddenAt[hunk.first] = h
		else
			for i = math.max(1, hunk.first - CONTEXT), math.min(n, hunk.last + CONTEXT) do
				buffer.writeu8(show, i - 1, 1)
			end
		end
	end
	local force = l.force
	if force then
		for i = 0, n - 1 do
			if buffer.readu8(force, i) == 1 then
				buffer.writeu8(show, i, 1)
			end
		end
	end
	local i = 1
	while i <= n do
		local h = hiddenAt[i]
		if h then
			push(MARKED, i, h)
			i = f.hunks[h].last + 1
		elseif buffer.readu8(show, i - 1) == 1 then
			local li, ri = oldAt(f, i), newAt(f, i)
			if not l.unified or (li > 0 and ri > 0 and chgAt(f, i) == 0) then
				push(PAIR, i, 0)
			else
				if li > 0 then
					push(PAIR, i, 1)
				end
				if ri > 0 then
					push(PAIR, i, 2)
				end
			end
			i += 1
		else
			local j = i
			while j + 1 <= n and buffer.readu8(show, j) == 0 and hiddenAt[j + 1] == nil do
				j += 1
			end
			push(FOLD, i, j)
			i = j + 1
		end
	end
	l.kind, l.a, l.b = kind, a, b
end

-- The local row of `l` at pair `p`: the pair's own row (in unified, its row for `side` when it has
-- one, else its first), or the fold or hidden hunk holding it.
local function rowOfPair(l: Layout, p: number, side: number?): number
	local lo, hi, best = 2, #l.kind, 1
	while lo <= hi do
		local mid = (lo + hi) // 2
		if l.a[mid] <= p and l.kind[mid] ~= NOTE then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	if l.kind[best] == PAIR and l.a[best] == p and best > 1 and l.kind[best - 1] == PAIR and l.a[best - 1] == p and l.b[best] ~= side then
		best -= 1
	end
	return best
end

-- Stable node key of local row `r`.
local function rowKey(l: Layout, r: number): string
	local id = l.file.id
	local k = l.kind[r]
	if k == HEAD then
		return "f" .. id .. "h"
	elseif k == PAIR then
		local side = l.b[r]
		return "f" .. id .. "p" .. l.a[r] .. (if side == 1 then "o" elseif side == 2 then "n" else "")
	elseif k == FOLD then
		return "f" .. id .. "z" .. l.a[r]
	elseif k == MARKED then
		return "f" .. id .. "m" .. l.b[r]
	end
	return "f" .. id .. "n"
end

-- The index into `starts` (ascending first rows, of layouts or pages) whose range holds
-- global row `g`, and `g`'s row within it.
local function locate(starts: { number }, g: number): (number, number)
	local lo, hi, best = 1, #starts, 1
	while lo <= hi do
		local mid = (lo + hi) // 2
		if starts[mid] <= g then
			best = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	return best, g - starts[best] + 1
end

-- Where the cursor stands, to find it again after rows change (a relayout, or files arriving
-- while loading): layout, row kind, pair, and a unified pair row's side (Layout `b`).
local function anchor(s: State): (number, number, number, number)
	if s.total == 0 then
		return 1, HEAD, 0, 0
	end
	local li, r = locate(s.starts, s.cur)
	local l = s.layouts[li]
	return li, l.kind[r], l.a[r], l.b[r]
end

-- Row starts and pages again after layouts changed or arrived; the cursor goes back to
-- the row `anchor` named before the change.
local function reindex(s: State, li: number, kind: number, pair: number, side: number)
	local starts: { number } = {}
	local at = 1
	for i, l in s.layouts do
		starts[i] = at
		at += #l.kind
	end
	s.starts, s.total = starts, at - 1

	-- First global row of each page of at most PAGE_ROWS rows. A file starts a new page when it
	-- doesn't fit in the current one; a file longer than a page breaks after its last fold or
	-- hidden hunk that fits, else at the limit.
	local pages = { 1 }
	local size = 0
	for i, l in s.layouts do
		local n = #l.kind
		if size > 0 and size + n > PAGE_ROWS then
			table.insert(pages, starts[i])
			size = 0
		end
		local r = 1
		while n - r + 1 > PAGE_ROWS - size do
			local cut = r + PAGE_ROWS - size - 1
			local b = cut
			while b > r and l.kind[b] ~= FOLD and l.kind[b] ~= MARKED do
				b -= 1
			end
			if b == r then
				b = cut
			end
			table.insert(pages, starts[i] + b)
			r = b + 1
			size = 0
		end
		size += n - r + 1
	end
	s.pages = pages

	local l = s.layouts[li]
	if l == nil then
		s.cur = 1
		return
	end
	local r = if kind == HEAD or kind == NOTE then 1 else rowOfPair(l, pair, if kind == PAIR then side else nil)
	s.cur = math.clamp(starts[li] + r - 1, 1, math.max(1, s.total))
end

-- Lays out the given layouts again (all when nil), keeping the cursor on its row.
local function relayout(s: State, only: { Layout }?)
	local li, kind, pair, side = anchor(s)
	local hide = hideFn(s)
	for _, l in only or s.layouts do
		layout(l, hide)
	end
	reindex(s, li, kind, pair, side)
end

-- The cursor's page: its index and its first and last global rows.
local function pageOf(s: State): (number, number, number)
	local p = locate(s.pages, s.cur)
	return p, s.pages[p], (s.pages[p + 1] or s.total + 1) - 1
end

-- Scrolls the cursor's row into view (its page is the one drawn): a header or note is a child of
-- the grid, a file's other rows are pieces in its block's columns, found by the gutter column `a`.
local function reveal(s: State)
	if s.total == 0 then
		return
	end
	local li, r = locate(s.starts, s.cur)
	local l = s.layouts[li]
	local key = rowKey(l, r)
	local path = if l.kind[r] == HEAD or l.kind[r] == NOTE then "main.g." .. key else string.format("main.g.b%d.a.%s", l.file.id, key)
	s.cx:frame({ { "reveal", path, "nearest" } })
end

---------------------------------------------------------------------------
-- Rows to nodes

local function span(class: string?, text: string): Node
	return ui.el("span", { class = class, text = text })
end

-- A code piece of row `key` (rowCls: the row's classes, " dv-cur" on the cursor's row): the line
-- split at novel-token and search-hit boundaries, so every byte sits in exactly one leaf span. A
-- line with no counterpart is changed whole: the piece's tint marks it, and its tokens get no spans.
local function codeCell(s: State, f: File, side: number, line: number, changed: boolean, whole: boolean, key: string, rowCls: string): Node
	local sideClass = (if side == 1 then "dv-r dv-c dv-o" else "dv-r dv-c dv-n") .. rowCls
	local act = { click = "row=" .. key }
	if line == 0 then
		return ui.el("div", { key = key, class = sideClass .. " dv-pad", actions = act })
	end
	local class = sideClass .. (if changed then " dv-chg" else "") .. (if whole then " dv-whole" else "")
	local text = lineText(s, f, side, line)
	local novel = if whole then nil elseif side == 1 then f.novelL[line] else f.novelR[line]
	local h = s.search.hits
	local hitList: { number }? = nil
	if h then
		local per = h.byLine[f.id]
		hitList = if per then per[side][line] else nil
	end
	if novel == nil and hitList == nil then
		return ui.el("div", { key = key, class = class, actions = act }, { span("dv-t", text) })
	end
	local cuts: { number } = { 0, #text }
	if novel then
		for _, c in novel do
			table.insert(cuts, math.min(c.s, #text))
			table.insert(cuts, math.min(c.e, #text))
		end
	end
	if h and hitList then
		for _, i in hitList do
			table.insert(cuts, math.min(h.s[i], #text))
			table.insert(cuts, math.min(h.e[i], #text))
		end
	end
	table.sort(cuts)
	local kids: { Node } = {}
	local prev = -1
	for k = 1, #cuts - 1 do
		local a, b = cuts[k], cuts[k + 1]
		if b > a and a ~= prev then
			prev = a
			local cls: { string } = {}
			if novel then
				for _, c in novel do
					if c.s <= a and a < c.e then
						table.insert(cls, "dv-nov")
						break
					end
				end
			end
			if h and hitList then
				for _, i in hitList do
					if h.s[i] <= a and a < h.e[i] then
						table.insert(cls, if i == s.search.cur then "dv-hit dv-hcur" else "dv-hit")
						break
					end
				end
			end
			table.insert(kids, span(if #cls > 0 then table.concat(cls, " ") else nil, string.sub(text, a + 1, b)))
		end
	end
	return ui.el("div", { key = key, class = class, actions = act }, { ui.el("span", { class = "dv-t" }, kids) })
end

local function glyph(m: string?): string
	return if m == "r" then "✓" elseif m == "s" then "•" else " "
end

local function hunkCounts(s: State, f: File): (number, number, number)
	local seen, reviewed = 0, 0
	for _, h in f.hunks do
		local m = markOf(s, h.key)
		if m == "r" then
			reviewed += 1
		elseif m == "s" then
			seen += 1
		end
	end
	return #f.hunks - seen - reviewed, seen, reviewed
end

-- First index of the sorted `list` holding a value >= `x`.
local function lowerBound(list: { number }, x: number): number
	local lo, hi = 1, #list + 1
	while lo < hi do
		local mid = (lo + hi) // 2
		if list[mid] < x then
			lo = mid + 1
		else
			hi = mid
		end
	end
	return lo
end

-- Search hits of file `f` whose pair is within [from, to].
local function hitsIn(s: State, f: File, from: number, to: number): number
	local h = s.search.hits
	local ps = if h then h.pairs[f.id] else nil
	if ps == nil then
		return 0
	end
	return lowerBound(ps, to + 1) - lowerBound(ps, from)
end

local function plural(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

-- A row's props: its stable key, also as `data-k` (what the replay harness reads back), and a click that puts the cursor on it.
local function rowProps(key: string, class: string, text: string?): { [string]: any }
	return { key = key, class = class, text = text, attrs = { ["data-k"] = key }, actions = { click = "row=" .. key } }
end

-- Remembers `nodes` as row `key`'s drawing, and `lines` as its code columns' text, while `sig` holds.
local function remember(s: State, key: string, sig: string, nodes: { Node }, lines: { string }?): ({ Node }, { string }?)
	if s.cache[key] == nil then
		if s.cached > NODE_CACHE then
			s.cache, s.cached = {}, 0
		end
		s.cached += 1
	end
	s.cache[key] = { sig = sig, nodes = nodes, lines = lines }
	return nodes, lines
end

-- Whether hit list `list` holds the current hit.
local function holdsCur(list: { number }?, cur: number): boolean
	if list == nil or cur == 0 then
		return false
	end
	for _, i in list do
		if i == cur then
			return true
		end
	end
	return false
end

-- Row `r`'s nodes: one for a whole row (header, note), else one piece per column of its file's
-- block, and the text each code column shows on the row (see view).
local function rowNode(s: State, l: Layout, r: number, isCur: boolean): ({ Node }, { string }?)
	local key = rowKey(l, r)
	local f = l.file
	local kind = l.kind[r]
	local cls = if isCur then " dv-cur" else ""
	-- `sig` names the parts of the state this row draws: the cached nodes are reused while
	-- they hold, so a search, a mark or a cursor move redraws only the rows it touches.
	local sig = cls .. (if l.unified then "u" else "s")
	local h = s.search.hits
	if kind == PAIR then
		local i = l.a[r]
		local hk = hunkAt(f, i)
		local mark = " "
		-- On the hunk's first row: a unified pair's old row, when it has one.
		if hk and f.hunks[hk].first == i and not (r > 1 and l.kind[r - 1] == PAIR and l.a[r - 1] == i) then
			mark = glyph(markOf(s, f.hunks[hk].key))
		end
		sig ..= mark
		local old: { number }?, new: { number }? = nil, nil
		if h then
			local per = h.byLine[f.id]
			old = if per then per[1][oldAt(f, i)] else nil
			new = if per then per[2][newAt(f, i)] else nil
			if old or new then
				local held = if holdsCur(old, s.search.cur) or holdsCur(new, s.search.cur) then s.search.cur else 0
				sig ..= "h" .. s.search.gen .. ":" .. held
			end
		end
		local hit = s.cache[key]
		if hit and hit.sig == sig then
			return hit.nodes, hit.lines
		end
		local li, ri, c = oldAt(f, i), newAt(f, i), chgAt(f, i)
		local act = { click = "row=" .. key }
		local rowCls = " dv-p" .. cls
		if not l.unified then
			-- The gutter (mark, old line number), the old code, the new line number, the new code.
			return remember(s, key, sig, {
				ui.el("div", { key = key, class = "dv-r dv-ga" .. rowCls, attrs = { ["data-k"] = key }, actions = act }, {
					span("dv-mk", mark),
					span("dv-ln", if li > 0 then tostring(li) else ""),
				}),
				codeCell(s, f, 1, li, bit32.band(c, 1) ~= 0, ri == 0, key, rowCls),
				ui.el("div", { key = key, class = "dv-r dv-ln dv-ln2" .. rowCls, text = if ri > 0 then tostring(ri) else "", actions = act }),
				codeCell(s, f, 2, ri, bit32.band(c, 2) ~= 0, li == 0, key, rowCls),
			}, { if li > 0 then lineText(s, f, 1, li) else "", if ri > 0 then lineText(s, f, 2, ri) else "" })
		end
		-- Unified: the gutter (mark, both line numbers) and the code of the side the row shows
		-- (Layout `b`); a changed pair's rows are tinted whole. An unchanged pair's one row
		-- shows the new line, or the old one when only it has hits or it holds the current hit, so
		-- an old-side match is drawn.
		local side = l.b[r]
		local shown = if side == 1 or (side == 0 and old and (new == nil or holdsCur(old, s.search.cur))) then 1 else 2
		return remember(s, key, sig, {
			ui.el("div", { key = key, class = "dv-r dv-ga" .. rowCls, attrs = { ["data-k"] = key }, actions = act }, {
				span("dv-mk", mark),
				span("dv-ln", if side ~= 2 and li > 0 then tostring(li) else ""),
				span("dv-ln dv-ln2", if side ~= 1 and ri > 0 then tostring(ri) else ""),
			}),
			if shown == 1 then codeCell(s, f, 1, li, side == 1, side == 1 and ri == 0, key, rowCls) else codeCell(s, f, 2, ri, side == 2, side == 2 and li == 0, key, rowCls),
		}, { if shown == 1 then lineText(s, f, 1, li) else lineText(s, f, 2, ri) })
	elseif kind == HEAD then
		local unseen, seen, reviewed = hunkCounts(s, f)
		local matches = hitsIn(s, f, 0, math.max(f.n, 1))
		sig ..= string.format("%s%d.%d.%d.%d", if l.collapsed then "c" else "o", unseen, seen, reviewed, matches)
		local hit = s.cache[key]
		if hit and hit.sig == sig then
			return hit.nodes, hit.lines
		end
		local kids: { Node } = {
			span(nil, if l.collapsed then "▸ " else "▾ "),
			span("dv-path", f.path),
		}
		if f.oldPath then
			table.insert(kids, span("dv-dim", "  ← " .. f.oldPath))
		end
		if f.language then
			table.insert(kids, span("dv-dim", "  " .. f.language))
		end
		if f.added then
			table.insert(kids, span("dv-dim", "  new file"))
		elseif f.deleted then
			table.insert(kids, span("dv-dim", "  deleted"))
		end
		if f.modes then
			table.insert(kids, span("dv-dim", "  " .. f.modes))
		end
		if f.added_rows > 0 then
			table.insert(kids, span("dv-plus", string.format("  +%d", f.added_rows)))
		end
		if f.removed_rows > 0 then
			table.insert(kids, span("dv-minus", string.format("  −%d", f.removed_rows)))
		end
		if #f.hunks > 0 then
			local text = string.format("  %s: %d unseen", plural(#f.hunks, "hunk", "hunks"), unseen)
			if seen > 0 then
				text ..= string.format(" · %d •", seen)
			end
			if reviewed > 0 then
				text ..= string.format(" · %d ✓", reviewed)
			end
			table.insert(kids, span(if unseen == 0 then "dv-done" else "dv-dim", text))
		end
		if matches > 0 then
			table.insert(kids, span("dv-hits", "  · " .. plural(matches, "match", "matches")))
		end
		return remember(s, key, sig, { ui.el("div", rowProps(key, "dv-r dv-hd" .. cls), kids) })
	elseif kind == FOLD or kind == MARKED then
		local text: string, band: string
		if kind == FOLD then
			local from, to = l.a[r], l.b[r]
			local n = hitsIn(s, f, from, to)
			sig ..= to .. ":" .. n
			text = "⋯ " .. plural(to - from + 1, "unchanged line", "unchanged lines") .. (if n > 0 then " · " .. plural(n, "match", "matches") else "")
			band = "dv-r dv-fold" .. cls
		else
			local hunk = f.hunks[l.b[r]]
			local m = markOf(s, hunk.key)
			local n = hitsIn(s, f, hunk.first, hunk.last)
			sig ..= (m or "") .. n
			text = string.format("%s %s hunk · %s", glyph(m), if m == "r" then "reviewed" else "seen", plural(hunk.last - hunk.first + 1, "row", "rows"))
				.. (if n > 0 then " · " .. plural(n, "match", "matches") else "")
			band = "dv-r dv-hidden" .. cls
		end
		local hit = s.cache[key]
		if hit and hit.sig == sig then
			return hit.nodes, hit.lines
		end
		-- The text goes in the first code column, held at its left edge while the code scrolls
		-- sideways (viewer.css .dv-ft); the other pieces are blank.
		local act = { click = "row=" .. key }
		local nodes: { Node } = {
			ui.el("div", { key = key, class = band .. " dv-ga", attrs = { ["data-k"] = key }, actions = act }),
			ui.el("div", { key = key, class = band, actions = act }, { span("dv-ft", text) }),
		}
		if not l.unified then
			table.insert(nodes, ui.el("div", { key = key, class = band, actions = act }))
			table.insert(nodes, ui.el("div", { key = key, class = band, actions = act }))
		end
		return remember(s, key, sig, nodes, if l.unified then { "" } else { "", "" })
	end
	return { ui.el("div", rowProps(key, "dv-r dv-note" .. cls, f.note or "")) }, nil
end

-- The row at a page's top (dir -1) or bottom (dir 1) of page `p`: a click changes page.
local function edgeNode(s: State, p: number, dir: number): Node
	local key = if dir > 0 then "pgnext" else "pgprev"
	local text: string
	if dir > 0 then
		local li, r = locate(s.starts, s.pages[p + 1])
		text = string.format("Next page %d/%d → %s%s", p + 1, #s.pages, s.layouts[li].file.path, if r > 1 then " (continued)" else "")
	else
		text = string.format("← Previous page %d/%d", p - 1, #s.pages)
	end
	return ui.el("div", { key = key, class = "dv-r dv-page", text = text, attrs = { ["data-k"] = key }, actions = { click = "page=" .. (if dir > 0 then "next" else "prev") } })
end

local function counts(s: State): (number, number, number, number)
	local unseen, seen, reviewed, total = 0, 0, 0, 0
	for _, l in s.layouts do
		local u, se, r = hunkCounts(s, l.file)
		unseen += u
		seen += se
		reviewed += r
		total += #l.file.hunks
	end
	return unseen, seen, reviewed, total
end

local function dockNode(s: State): Node
	local unseen, seen, reviewed, total = counts(s)
	local status = string.format("%s · hunks: %d unseen · %d seen • · %d reviewed ✓ of %d", plural(#s.layouts, "file", "files"), unseen, seen, reviewed, total)
	if s.since then
		status ..= " · unmarked only"
	end
	if s.loading then
		status ..= " · loading…"
	end
	if s.leftOut > 0 then
		status ..= string.format(" · %d left out (memory)", s.leftOut)
	end
	if #s.pages > 1 then
		status ..= string.format(" · page %d/%d", (pageOf(s)), #s.pages)
	end
	if s.hx > 0 then
		status ..= string.format(" · from column %d (0 resets)", s.hx + 1)
	end
	local line2: string
	local p = s.prompt
	if p then
		line2 = "/" .. p.text .. "▏  [" .. p.sides .. "]"
		local h = s.search.hits
		if s.search.error then
			line2 ..= "  " .. s.search.error
		elseif h and h.query.text == p.text then
			line2 ..= string.format("  %s", plural(h.total, "match", "matches"))
		end
	elseif s.search.hits then
		local h = s.search.hits :: Hits
		line2 = string.format("/%s  %d/%d  [%s]", h.query.text, s.search.cur, h.total, h.query.sides)
		if h.query.fellBack then
			line2 ..= " · searched literally (not a valid regex)"
		end
		if h.total > #h.f then
			line2 ..= string.format(" (first %d shown)", #h.f)
		end
	elseif s.search.error then
		line2 = s.search.error
	else
		line2 = s.message or "? keys · ]/[ hunks · }/{ files · / search · R/r reviewed · u unmarked only · Enter open"
	end
	return ui.col({
		ui.el("div", { key = "status", class = "dv-dl", text = status }),
		ui.el("div", { key = "line2", class = "dv-dl dv-dl2", text = line2 }),
	})
end

local HELP = {
	"j k ↓ ↑        cursor down, up",
	"ctrl-d ctrl-u  half screen      ctrl-f ctrl-b  screen",
	"ctrl-e ctrl-y  scroll a line    g G            top, bottom",
	"] [            next, previous hunk (across files)",
	"} {            next, previous file",
	"> <            next, previous page (a diff over 1,500 rows; jumps change pages too)",
	"/ n N Esc      search, next, previous, clear  (Tab in / cycles sides; \\c \\C case; \\V literal)",
	"space          unfold here; on a file header, collapse or expand the file",
	"o O            expand every file, collapse every file and fold its unchanged code again",
	"R r            reviewed: hunk, file   (• seen is automatic)",
	"u              unmarked hunks only",
	"h l ← →        sideways 4 columns, both sides   H L ⇧← ⇧→  half a code column",
	"0 $            sideways: back to the start, to the end of the cursor's line",
	"               a trackpad swipe or shift-wheel scrolls the code column under the pointer",
	"v V            unified or side by side: this file, every file (V is remembered)",
	"Enter          open the file at this line",
	"? q            help, close",
}

local function render(s: State)
	s.lastRender = tern.now()
	s.renderDue = false
	s.cx:render()
end

---------------------------------------------------------------------------
-- Seen

-- Arms the timer that marks the hunk under the cursor seen: it needs SEEN_MS with no key
-- (Tern doesn't tell a block what the wheel shows).
local function scheduleSeen(s: State)
	if s.seen then
		s.seen:cancel()
	end
	s.seen = tern.timer(SEEN_MS, function()
		if s.dead or s.total == 0 or s.marks == nil then
			return
		end
		local li, r = locate(s.starts, s.cur)
		local l = s.layouts[li]
		if l.kind[r] ~= PAIR then
			return
		end
		local h = hunkAt(l.file, l.a[r])
		if h and markOf(s, l.file.hunks[h].key) == nil then
			markHunk(s, l.file, h, "s")
			render(s)
		end
	end)
end

---------------------------------------------------------------------------
-- Navigation

local function moveTo(s: State, g: number)
	s.cur = math.clamp(g, 1, math.max(1, s.total))
	reveal(s)
end

-- The first row of the next (dir 1) or previous (dir -1) page.
local function pageJump(s: State, dir: number): boolean
	local target = s.pages[(pageOf(s)) + dir]
	if target == nil then
		return false
	end
	moveTo(s, target)
	return true
end

-- Next (dir 1) or previous (dir -1) hunk, across files; expands a collapsed file it lands in.
local function hunkJump(s: State, dir: number): boolean
	if s.total == 0 then
		return false
	end
	local li, r = locate(s.starts, s.cur)
	local cl = s.layouts[li]
	local pair = if cl.kind[r] == HEAD then 0 else cl.a[r]
	local hide = hideFn(s)
	local function usable(l: Layout, h: number): boolean
		return not (hide and not l.shown[h] and hide(l.file, h))
	end
	local i = li
	while i >= 1 and i <= #s.layouts do
		local l = s.layouts[i]
		local hs = l.file.hunks
		local found: number? = nil
		if dir > 0 then
			for h = 1, #hs do
				if (i > li or hs[h].first > pair) and usable(l, h) then
					found = h
					break
				end
			end
		else
			for h = #hs, 1, -1 do
				if (i < li or hs[h].first < pair) and usable(l, h) then
					found = h
					break
				end
			end
		end
		if found then
			if l.collapsed then
				l.collapsed = false
				relayout(s, { l })
			end
			moveTo(s, s.starts[i] + rowOfPair(l, hs[found].first) - 1)
			return true
		end
		i += dir
	end
	return false
end

local function fileJump(s: State, dir: number): boolean
	if s.total == 0 then
		return false
	end
	local li, r = locate(s.starts, s.cur)
	local target = li + dir
	if dir < 0 and r > 1 then
		target = li
	end
	if target < 1 or target > #s.layouts then
		return false
	end
	moveTo(s, s.starts[target])
	return true
end

-- The next (forward) or previous hit in row order, wrapping, and the cursor onto it: its file
-- is expanded, the folds around it unfolded and its hidden hunk shown.
local function hitJump(s: State, forward: boolean): boolean
	local h = s.search.hits
	if h == nil or #h.f == 0 or s.total == 0 then
		return false
	end
	local n = #h.f
	local idx: number
	if s.search.cur > 0 and s.search.at == s.cur then
		idx = s.search.cur + (if forward then 1 else -1)
		if idx > n then
			idx = 1
		elseif idx < 1 then
			idx = n
		end
	else
		local li, r = locate(s.starts, s.cur)
		local cl = s.layouts[li]
		local fid = cl.file.id
		local pair = if cl.kind[r] == HEAD then 0 else cl.a[r]
		-- The first hit after (file id, pair) going forward, the last one before it going back.
		local lo, hi = 1, n + 1
		while lo < hi do
			local mid = (lo + hi) // 2
			local hf, hp = h.f[mid], h.pair[mid]
			if hf < fid or (hf == fid and (hp < pair or (forward and hp == pair))) then
				lo = mid + 1
			else
				hi = mid
			end
		end
		if forward then
			idx = if lo > n then 1 else lo
		else
			idx = if lo - 1 < 1 then n else lo - 1
		end
	end
	local l = s.layouts[h.f[idx]]
	local f = l.file
	local p = h.pair[idx]
	local changed = false
	if l.collapsed then
		l.collapsed = false
		changed = true
	end
	local hk = hunkAt(f, p)
	if hk and s.since and not l.shown[hk] then
		l.shown[hk] = true
		changed = true
	end
	if changed then
		relayout(s, { l })
	end
	local row = rowOfPair(l, p, h.side[idx])
	if l.kind[row] ~= PAIR or l.a[row] ~= p then
		forcePairs(l, p - CONTEXT, p + CONTEXT)
		relayout(s, { l })
		row = rowOfPair(l, p, h.side[idx])
	end
	s.search.cur = idx
	moveTo(s, s.starts[h.f[idx]] + row - 1)
	s.search.at = s.cur
	return true
end

---------------------------------------------------------------------------
-- Search

-- Parses `p.out` (rg's lines) until the slice is used up, then reschedules itself; at the
-- end orders the hits as the rows show them (file, pair, old before new, column), indexes
-- them and publishes the result.
local function stepSearch(s: State, seq: number, p: Parser)
	if s.dead or s.search.seq ~= seq then
		return
	end
	local t0 = tern.now()
	local deadline = t0 + 20
	local out, h = p.out, p.hits
	local find, sub, match = string.find, string.sub, string.match
	while p.pos <= #out do
		if tern.now() > deadline then
			tern.timer(1, function()
				stepSearch(s, seq, p)
			end)
			return
		end
		local nl = find(out, "\n", p.pos, true) or (#out + 1)
		local nul = find(out, "\0", p.pos, true)
		if nul and nul < nl then
			local path = sub(out, p.pos, nul - 1)
			local line, col, at = match(out, "^(%d+):(%d+):()", nul + 1)
			local target = p.paths[path]
			if line and col and at and target then
				h.total += 1
				if #h.f < MAX_HITS then
					local f, side = target.f, target.side
					local ln = tonumber(line) :: number
					local c = (tonumber(col) :: number) - 1
					-- The pair of line `ln`: the line -> pair map of this file and side is built on first use.
					local per = s.pairIndex[f.id]
					if per == nil then
						per = {}
						s.pairIndex[f.id] = per
					end
					local map = per[side]
					if map == nil then
						local lines = if side == 1 then f.oldLines else f.newLines
						map = buffer.create((lines + 2) * 4)
						for i = 1, f.n do
							local x = if side == 1 then oldAt(f, i) else newAt(f, i)
							if x > 0 and x <= lines + 1 then
								buffer.writeu32(map, x * 4, i)
							end
						end
						per[side] = map
					end
					table.insert(h.f, f.id)
					table.insert(h.side, side)
					table.insert(h.line, ln)
					table.insert(h.s, c)
					table.insert(h.e, c + (nl - (at :: number)))
					table.insert(h.pair, if ln * 4 + 4 > buffer.len(map) then 0 else buffer.readu32(map, ln * 4))
				end
			end
		end
		p.pos = nl + 1
	end

	local n = #h.f
	local order: { number } = {}
	for i = 1, n do
		order[i] = i
	end
	table.sort(order, function(a: number, b: number): boolean
		if h.f[a] ~= h.f[b] then
			return h.f[a] < h.f[b]
		elseif h.pair[a] ~= h.pair[b] then
			return h.pair[a] < h.pair[b]
		elseif h.side[a] ~= h.side[b] then
			return h.side[a] < h.side[b]
		end
		return h.s[a] < h.s[b]
	end)
	local function permute(t: { number }): { number }
		local sorted: { number } = {}
		for i, j in order do
			sorted[i] = t[j]
		end
		return sorted
	end
	h.f, h.side, h.line, h.s, h.e, h.pair = permute(h.f), permute(h.side), permute(h.line), permute(h.s), permute(h.e), permute(h.pair)
	for i = 1, n do
		local fid, side, line = h.f[i], h.side[i], h.line[i]
		local perFile = h.byLine[fid]
		if perFile == nil then
			perFile = { {}, {} }
			h.byLine[fid] = perFile
		end
		local perLine = perFile[side][line]
		if perLine == nil then
			perLine = {}
			perFile[side][line] = perLine
		end
		table.insert(perLine, i)
		local ps = h.pairs[fid]
		if ps == nil then
			ps = {}
			h.pairs[fid] = ps
		end
		table.insert(ps, h.pair[i])
	end

	s.search.hits = h
	s.search.gen += 1
	s.search.cur, s.search.at = 0, 0
	metric("search", { ms = tern.now() - t0, hits = #h.f, total = h.total, mem = memKB(s) })
	-- While typing, and once after Enter, the cursor goes to the first match after where
	-- the prompt opened (vim's incsearch).
	local pr = s.prompt
	if (pr or s.search.jump) and #h.f > 0 then
		s.cur = if pr then pr.cur else s.search.from
		s.search.jump = false
		hitJump(s, true)
	end
	render(s)
end

-- Runs rg for the typed text (`literal`: search it literally, after rg rejected it as a regex).
local function runSearch(s: State, seq: number, literal: boolean?)
	local dir = s.dir
	if dir == nil or s.search.seq ~= seq then
		return
	end
	-- vim's flags in the typed text: `\V` first makes it literal, `\c` / `\C` force the case.
	local text, sides = s.search.text, s.search.sides
	local pattern = text
	local asText = false
	if string.sub(pattern, 1, 2) == "\\V" then
		asText = true
		pattern = string.sub(pattern, 3)
	end
	local case = "smart"
	if string.find(pattern, "\\C", 1, true) then
		case = "sensitive"
	elseif string.find(pattern, "\\c", 1, true) then
		case = "ignore"
	end
	pattern = string.gsub(string.gsub(pattern, "\\C", ""), "\\c", "")
	if pattern == "" then
		s.search.hits, s.search.error = nil, nil
		render(s)
		return
	end
	local q: Query = { text = text, sides = sides, fellBack = nil }
	if literal then
		asText, q.fellBack = true, true
	end
	local argv = { RG, "--no-config", "-uu", "--null", "--no-heading", "--with-filename", "--line-number", "--column", "--only-matching", "--color", "never" }
	table.insert(argv, if case == "ignore" then "-i" elseif case == "sensitive" then "-s" else "-S")
	if asText then
		table.insert(argv, "-F")
	end
	table.insert(argv, "-e")
	table.insert(argv, pattern)
	table.insert(argv, "--")
	if sides ~= "new" and tern.fs.exists(dir .. "/old") then
		table.insert(argv, "old")
	end
	if sides ~= "old" and tern.fs.exists(dir .. "/new") then
		table.insert(argv, "new")
	end
	local hits: Hits = { query = q, f = {}, side = {}, line = {}, s = {}, e = {}, pair = {}, total = 0, byLine = {}, pairs = {} }
	if argv[#argv] == "--" then
		s.search.hits = hits
		render(s)
		return
	end
	tern.process.run(argv, { cwd = dir, env = { PATH = PATH }, timeout_ms = 20000 }, function(r: ProcessResult)
		if s.dead or s.search.seq ~= seq then
			return
		end
		if r.status == 2 or r.status < 0 then
			-- What vim reads as text (`loop {`, `a(`) is often not a valid Rust regex: search it literally.
			if not asText and string.find(r.stderr, "regex parse error", 1, true) then
				runSearch(s, seq, true)
				return
			end
			s.search.error = (string.match(r.stderr, "[^\n]*error[^\n]*") or string.match(r.stderr, "[^\n]+") or "rg failed") :: string
			s.search.hits = nil
			render(s)
			return
		end
		s.search.error = nil
		-- Only files that show rows: a file difftastic calls unchanged (a whitespace-only
		-- edit, say) or a note has no line to put a hit on, so its matches don't count.
		local paths: { [string]: { f: File, side: number } } = {}
		for _, l in s.layouts do
			local f = l.file
			if f.n > 0 then
				if f.hasOld then
					paths["old/" .. (f.oldPath or f.path)] = { f = f, side = 1 }
				end
				if f.hasNew then
					paths["new/" .. f.path] = { f = f, side = 2 }
				end
			end
		end
		stepSearch(s, seq, { out = r.stdout, pos = 1, hits = hits, paths = paths })
	end)
end

local function searchSoon(s: State)
	s.search.seq += 1
	local seq = s.search.seq
	tern.timer(SEARCH_DELAY_MS, function()
		runSearch(s, seq)
	end)
end

---------------------------------------------------------------------------
-- Loading

-- Models record `rec` (the next file dft wrote), keys its hunks and lays it out.
local function addFile(s: State, rec: any)
	local id = #s.layouts + 1
	local f: File
	if memKB(s) > MEMORY_STOP_KB then
		s.leftOut += 1
		f = fromRecord(id, { path = if type(rec) == "table" then rec.path else "?", note = "left out: the viewer's memory budget is used up; narrow the range" })
	elseif type(rec) ~= "table" then
		f = fromRecord(id, { path = "?", note = "a record dft wrote could not be read" })
	else
		f = fromRecord(id, rec)
	end
	if #f.hunks > 0 then
		-- A hunk's key is the hash of the new path and the hunk's rows, each row as `-<old line>`
		-- and `+<new line>` (no line numbers, so moving the hunk keeps its key), then `:<k>` for
		-- the kth hunk of the file with that hash.
		local oldLines = if f.hasOld then readLines(s.texts, sidePath(s, f, 1)) else nil
		local newLines = if f.hasNew then readLines(s.texts, sidePath(s, f, 2)) else nil
		local seen: { [string]: number } = {}
		for _, h in f.hunks do
			local parts: { string } = { f.path, "\0" }
			for i = h.first, h.last do
				local ol, nl = oldAt(f, i), newAt(f, i)
				if ol > 0 then
					table.insert(parts, "-")
					table.insert(parts, if oldLines then oldLines[ol] or "" else "")
					table.insert(parts, "\n")
				end
				if nl > 0 then
					table.insert(parts, "+")
					table.insert(parts, if newLines then newLines[nl] or "" else "")
					table.insert(parts, "\n")
				end
			end
			local base = hash(table.concat(parts))
			local k = (seen[base] or 0) + 1
			seen[base] = k
			h.key = base .. ":" .. k
		end
	end
	s.maxLine = math.max(s.maxLine, f.oldLines, f.newLines)
	local l: Layout = { file = f, collapsed = false, unified = s.unified, force = nil, shown = {}, kind = {}, a = {}, b = {} }
	layout(l, hideFn(s))
	table.insert(s.layouts, l)
end

local function recordPath(dir: string, n: number): string
	return string.format("%s/records/%06d.json", dir, n)
end

local function tick(s: State, run: number)
	if s.dead or s.run ~= run then
		return
	end
	local dir = s.dir
	if dir == nil then
		return
	end
	local t0 = tern.now()
	local deadline = t0 + SLICE_MS
	if s.root == nil and tern.fs.exists(dir .. "/meta.json") then
		local meta = readJson(dir .. "/meta.json")
		if type(meta) == "table" and type(meta.root) == "string" then
			s.root = meta.root
			local path = tern.plugin.data .. "/marks/" .. hash(meta.root) .. ".json"
			s.marks = { path = path, root = meta.root, map = readMarks(path), changed = {}, dirty = false }
		end
	end
	local added = 0
	while tern.now() < deadline do
		local path = recordPath(dir, s.nextRec)
		if not tern.fs.exists(path) then
			break
		end
		addFile(s, readJson(path))
		s.nextRec += 1
		added += 1
	end
	if added > 0 then
		-- The new layouts went on the end, so the old starts still find the cursor.
		local li, kind, pair, side = anchor(s)
		reindex(s, li, kind, pair, side)
	end
	-- dft writes done.json after its last record.
	if tern.fs.exists(dir .. "/done.json") and not tern.fs.exists(recordPath(dir, s.nextRec)) then
		local done = readJson(dir .. "/done.json")
		s.loading = false
		if type(done) == "table" then
			if type(done.messages) == "string" and done.messages ~= "" then
				s.messages = done.messages
			end
			if type(done.status) == "number" and done.status ~= 0 and #s.layouts == 0 then
				s.failed = s.messages or ("dft exited " .. done.status)
			end
		end
	end
	metric("tick", { ms = tern.now() - t0, files = added, total = s.total, mem = memKB(s) })
	if not s.loading then
		local _, _, _, hunks = counts(s)
		metric("loaded", { ms = tern.now() - s.t0, files = #s.layouts, rows = s.total, pages = #s.pages, hunks = hunks, mem = memKB(s), peak = s.peak, args = if s.req then s.req.args else nil })
		render(s)
		scheduleSeen(s)
		-- A search typed while files arrived reruns over all of them.
		if s.search.text ~= "" then
			searchSoon(s)
		end
		return
	end
	if added > 0 then
		s.renderDue = true
	end
	if s.renderDue and tern.now() - s.lastRender >= RENDER_EVERY_MS then
		render(s)
	end
	tern.timer(TICK_MS, function()
		tick(s, run)
	end)
end

local function removeDir(dir: string?)
	if dir and tern.fs.exists(dir) then
		pcall(tern.fs.remove, dir)
	end
end

-- Emit folders of blocks from an earlier VM, which ended without cleaning up:
-- this VM's blocks make new ones. They live in this plugin's data folder, so a
-- second Tern (another config dir, a headless test run) never sweeps them.
do
	local ok, names = pcall(tern.fs.list, EMIT_ROOT)
	if ok then
		for _, name in names do
			pcall(tern.fs.remove, EMIT_ROOT .. "/" .. name)
		end
	end
end

-- Forgets what the block showed and runs `dft --emit` for its request.
local function startLoad(s: State)
	removeDir(s.dir)
	s.run += 1
	s.dir = nil
	s.root = nil
	s.layouts, s.starts, s.total, s.pages = {}, {}, 0, { 1 }
	s.nextRec, s.loading, s.failed, s.messages, s.leftOut = 1, false, nil, nil, 0
	s.cur, s.hx = 1, 0
	s.marks = nil
	s.texts.entries, s.texts.cost = {}, 0
	s.pairIndex = {}
	s.search = { hits = nil, cur = 0, at = 0, seq = s.search.seq + 1, text = "", sides = "both", error = nil, jump = false, from = 1, gen = s.search.gen + 1 }
	s.prompt = nil
	s.cache, s.cached = {}, 0
	s.maxLine = 0
	s.firstRows = false
	local req = s.req
	if req == nil then
		return
	end
	local run = s.run
	-- Wall-clock seconds make the name unique across VMs and daemon restarts
	-- (tern.now() starts over with the process); a leftover folder is removed first.
	local dir = string.format("%s/%d-%d-%d-%d", EMIT_ROOT, s.pane, run, os.time(), math.floor(tern.now()))
	removeDir(dir)
	s.dir = dir
	s.loading = true
	s.t0 = tern.now()
	local argv = { BUN, DFT, "--emit", dir }
	for _, a in req.args do
		table.insert(argv, a)
	end
	tern.process.run(argv, { cwd = req.cwd, env = { PATH = PATH } }, function(r: ProcessResult)
		if s.dead or s.run ~= run then
			return
		end
		if r.status ~= 0 and not tern.fs.exists(dir .. "/done.json") then
			s.loading = false
			local why = if r.stderr ~= "" then r.stderr elseif r.stdout ~= "" then r.stdout else string.format("dft exited %d", r.status)
			s.failed = why
			render(s)
		end
	end)
	tern.timer(TICK_MS, function()
		tick(s, run)
	end)
end

local function readRequest(path: string): Request?
	local value = readJson(path)
	if type(value) == "table" and type(value.cwd) == "string" and type(value.args) == "table" then
		local args: { string } = {}
		for _, a in value.args do
			table.insert(args, tostring(a))
		end
		return { cwd = value.cwd, args = args, seq = tonumber(value.seq) or 0, block = tonumber(value.block) }
	end
	return nil
end

-- Every REQUEST_POLL_MS: writes this block's heartbeat beside its request file
-- (<caller>.block, read by `dft --tab` to find an open viewer), and loads a
-- newer request that names this block.
local function pollRequest(s: State)
	tern.timer(REQUEST_POLL_MS, function()
		if s.dead then
			return
		end
		local path = s.reqPath
		if path then
			local beat = string.gsub(path, "%.dftview$", ".block")
			if beat ~= path then
				pcall(tern.fs.write, beat, tern.json.encode({ pane = s.pane, at = os.time() }))
			end
			local req = readRequest(path)
			local cur = s.req
			if req and req.block == s.pane and (cur == nil or req.seq ~= cur.seq) then
				saveMarks(s)
				s.req = req
				startLoad(s)
				render(s)
			end
		end
		pollRequest(s)
	end)
end

---------------------------------------------------------------------------
-- The block

local function note(text: string, tone: string?): Node
	return ui.col({ ui.el("div", { key = "note", class = "dv-msg" .. (if tone then " dv-" .. tone else ""), text = text }) })
end

local viewer: BlockDef<State> = {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		-- After a reload or restart, what this block showed (the request file may since name another viewer).
		local req: Request? = nil
		if type(saved) == "table" and type(saved.req) == "table" then
			local r = saved.req
			if type(r.cwd) == "string" and type(r.args) == "table" then
				local list: { string } = {}
				for _, a in r.args do
					table.insert(list, tostring(a))
				end
				local restored: Request = { cwd = tostring(r.cwd), args = list, seq = tonumber(r.seq) or 0, block = cx.pane }
				req = restored
			end
		end
		if req == nil and args[1] then
			req = readRequest(args[1])
		end
		-- `V`'s choice, kept for every viewer; a store that can't be read means side by side.
		local ok, unified = pcall(tern.kv.get, "unified")
		local s: State = {
			cx = cx,
			pane = cx.pane,
			reqPath = args[1],
			req = req,
			run = 0,
			dir = nil,
			root = nil,
			layouts = {},
			starts = {},
			total = 0,
			pages = { 1 },
			nextRec = 1,
			loading = false,
			failed = nil,
			messages = nil,
			leftOut = 0,
			cur = 1,
			hx = 0,
			unified = ok and unified == true,
			since = false,
			marks = nil,
			texts = { entries = {}, cost = 0, clock = 0 },
			pairIndex = {},
			search = { hits = nil, cur = 0, at = 0, seq = 0, text = "", sides = "both", error = nil, jump = false, from = 1, gen = 0 },
			prompt = nil,
			help = false,
			cache = {},
			cached = 0,
			seen = nil,
			lastRender = 0,
			renderDue = false,
			saveDue = false,
			t0 = tern.now(),
			firstFrame = false,
			firstRows = false,
			peak = 0,
			maxLine = 0,
			message = nil,
			dead = false,
		}
		live[cx.pane] = s
		-- Drops blocks whose panes are gone, with their emit folders.
		if not watching then
			watching = true
			local function check()
				local panes: { [number]: boolean } = {}
				for _, p in tern.pane.list() do
					panes[p.pane] = true
				end
				for pane, b in live do
					if not panes[pane] then
						b.dead = true
						removeDir(b.dir)
						saveMarks(b)
						live[pane] = nil
					end
				end
				if next(live) == nil then
					watching = false
					return
				end
				tern.timer(2000, check)
			end
			tern.timer(2000, check)
		end
		startLoad(s)
		pollRequest(s)
		metric("init", { pane = cx.pane, args = if req then req.args else nil })
		return s
	end,

	title = function(s: State): string?
		local req = s.req
		if req == nil then
			return "dft"
		end
		-- Commit ids shortened to 12 digits and the whole cut at 48 characters, so the tab bar stays readable.
		local parts: { string } = {}
		for _, a in req.args do
			local short = string.gsub(a, "%x+", function(id: string): string
				return if #id >= 32 then string.sub(id, 1, 12) else id
			end)
			table.insert(parts, short)
		end
		local title = "dft " .. table.concat(parts, " ")
		if (utf8.len(title) or #title) > 48 then
			title = string.sub(title, 1, (utf8.offset(title, 48) or 49) - 1) .. "…"
		end
		return title
	end,

	view = function(s: State, _cx: BlockCx): BlockView
		local t0 = tern.now()
		local out: BlockView = {}
		if s.req == nil then
			out.main = note("Open this pane with `dft --tab <jj diff arguments>`, or `d` in jjui.")
		elseif s.failed then
			out.main = note(s.failed :: string, "error")
		elseif s.total == 0 then
			out.main = note(if s.loading then "Comparing with difftastic…" else (s.messages or "No changes"))
			out.dock = dockNode(s)
		else
			local p, first, last = pageOf(s)
			local kids: { Node } = {}
			if p > 1 then
				table.insert(kids, edgeNode(s, p, -1))
			end
			local li, r = locate(s.starts, first)
			local pairsDrawn = 0
			-- A header or note is a row of the grid; a file's other rows go into its block, one list of
			-- pieces per column (rowNode): side by side the gutter `a`, the old code `o`, the new line
			-- numbers `b` and the new code `n`; unified the gutter and the code `u`. Each code column
			-- is a sideways scroller: a swipe or shift-wheel scrolls that column alone. Over its pieces
			-- lies Tern's own code node, a line per row, for syntax colors (viewer.css .dv-s > .sf-code);
			-- the pieces draw tints, changed tokens and hits. Wire tables, not ui.el/ui.col: those
			-- walk every descendant, and the rows are cached nodes already built.
			local cols: { { Node } } = {}
			local code: { { string } } = {}
			for g = first, last do
				local l = s.layouts[li]
				if r > #l.kind then
					li += 1
					r = 1
					l = s.layouts[li]
				end
				local kind = l.kind[r]
				if kind == PAIR then
					pairsDrawn += 1
				end
				local nodes, lines = rowNode(s, l, r, g == s.cur)
				if kind == HEAD or kind == NOTE then
					table.insert(kids, nodes[1])
				else
					for c, n in nodes do
						cols[c] = cols[c] or {}
						table.insert(cols[c], n)
					end
					for c, line in lines or {} do
						code[c] = code[c] or {}
						table.insert(code[c], line)
					end
					if g == last or r == #l.kind then
						-- The grammar is the extension's (Tern's code node takes `rs`, `ts`, `py`, …).
						local lang = string.match(l.file.path, "%.([%w_+-]+)$")
						local block: { Node } = {}
						for i, key in (if l.unified then { "a", "u" } else { "a", "o", "b", "n" }) do
							local col = cols[i]
							-- Even columns are code, sideways scrollers (viewer.css .dv-s), syntax layer last.
							if i % 2 == 0 then
								local layer = ui.code(table.concat(code[i // 2], "\n"), lang)
								layer.p = layer.p or {}
								;(layer.p :: any).key = "syntax"
								table.insert(col, layer)
							end
							table.insert(block, { k = "el", p = { tag = "div", key = key, class = if i % 2 == 0 then "dv-s" else nil }, c = col })
						end
						table.insert(kids, { k = "el", p = { tag = "div", key = "b" .. l.file.id, class = if l.unified then "dv-fb dv-fu" else "dv-fb" }, c = block })
						cols, code = {}, {}
					end
				end
				r += 1
			end
			if p < #s.pages then
				table.insert(kids, edgeNode(s, p, 1))
			end
			-- The keys' sideways shift (see key): a class per nonzero decimal digit, .dv-x<place>-<digit>.
			local shift = ""
			local x, place = s.hx, 0
			while x > 0 do
				if x % 10 > 0 then
					shift ..= string.format(" dv-x%d-%d", place, x % 10)
				end
				x //= 10
				place += 1
			end
			local grid: Node = { k = "el", p = { tag = "div", key = "g", class = string.format("dv-g dv-w%d%s", math.clamp(#tostring(s.maxLine), 3, 7), shift) }, c = kids }
			out.main = { k = "col", c = { grid } }
			out.dock = dockNode(s)
			if pairsDrawn > 0 and not s.firstRows then
				s.firstRows = true
				metric("firstrows", { ms = tern.now() - s.t0 })
			end
			metric("view", { ms = tern.now() - t0, drawn = last - first + 1, total = s.total, page = p, mem = memKB(s) })
		end
		if s.help then
			local lines: { Node } = {}
			for i, line in HELP do
				table.insert(lines, ui.el("div", { key = i, class = "dv-help-l", text = line }))
			end
			out.layer = ui.col({ ui.el("div", { key = "help", class = "dv-help" }, lines) })
		end
		local main = out.main
		if main then
			local p: { [string]: any } = main.p or {}
			p.role = "dft-viewer.main"
			main.p = p
		end
		if not s.firstFrame then
			s.firstFrame = true
			metric("firstframe", { ms = tern.now() - s.t0 })
		end
		return out
	end,

	key = function(s: State, k: Key, _cx: BlockCx): boolean?
		local t0 = tern.now()
		if s.seen then
			s.seen:cancel()
		end
		local handled = true
		local name = k.name
		-- The typed character, if the key is one.
		local ch = if k.ctrl or k.meta or k.text == nil or k.text == "" then nil else k.text
		local p = s.prompt
		if s.help then
			s.help = false
		elseif p then
			if name == "escape" then
				s.prompt = nil
				s.search.seq += 1
				s.search.hits, s.search.error, s.search.text = nil, nil, ""
				moveTo(s, p.cur)
			elseif name == "enter" then
				s.prompt = nil
				local h = s.search.hits
				if h and h.query.text == p.text and #h.f > 0 then
					-- The hits are in: put the cursor on the first (incsearch may already have).
					if s.search.cur == 0 then
						s.cur = p.cur
						hitJump(s, true)
					end
				else
					s.search.jump, s.search.from = true, p.cur
				end
			else
				if name == "backspace" then
					p.text = string.sub(p.text, 1, (utf8.offset(p.text, -1) or 1) - 1)
				elseif name == "tab" then
					p.sides = if p.sides == "both" then "new" elseif p.sides == "new" then "old" else "both"
				elseif k.ctrl and name == "u" then
					p.text = ""
				elseif k.ctrl and name == "w" then
					p.text = string.gsub(p.text, "%S*%s*$", "")
				elseif name == "paste" then
					p.text ..= string.match(k.text or "", "^[^\r\n]*") or ""
				elseif ch then
					p.text ..= ch
				else
					handled = false
				end
				if handled then
					s.search.text, s.search.sides = p.text, p.sides
					searchSoon(s)
				end
			end
		else
			-- The layout and row under the cursor, for the keys that act on them; none without rows.
			local l: Layout? = nil
			local r = 1
			if s.total > 0 then
				local li, row = locate(s.starts, s.cur)
				l, r = s.layouts[li], row
			end
			s.message = nil
			if ch == "j" or name == "down" then
				moveTo(s, s.cur + 1)
			elseif ch == "k" or name == "up" then
				moveTo(s, s.cur - 1)
			elseif k.ctrl and name == "d" then
				moveTo(s, s.cur + height(s.cx) // 2)
			elseif k.ctrl and name == "u" then
				moveTo(s, s.cur - height(s.cx) // 2)
			elseif (k.ctrl and name == "f") or name == "page_down" then
				moveTo(s, s.cur + height(s.cx) - 1)
			elseif (k.ctrl and name == "b") or name == "page_up" then
				moveTo(s, s.cur - (height(s.cx) - 1))
			elseif k.ctrl and (name == "e" or name == "y") then
				-- Native scrolling: the cursor stays where it is (the grid names the scroller).
				s.cx:frame({ { "scroll", "main.g", if name == "e" then "line-down" else "line-up" } })
				handled = false
			elseif ch == "g" or name == "home" then
				moveTo(s, 1)
			elseif ch == "G" or name == "end" then
				moveTo(s, s.total)
			elseif ch == "]" then
				handled = hunkJump(s, 1)
			elseif ch == "[" then
				handled = hunkJump(s, -1)
			elseif ch == "}" then
				handled = fileJump(s, 1)
			elseif ch == "{" then
				handled = fileJump(s, -1)
			elseif ch == ">" then
				handled = pageJump(s, 1)
			elseif ch == "<" then
				handled = pageJump(s, -1)
			elseif ch == "/" then
				s.prompt = { text = "", sides = s.search.sides, cur = s.cur }
				s.search.text = ""
			elseif ch == "n" then
				handled = hitJump(s, true)
			elseif ch == "N" then
				handled = hitJump(s, false)
			elseif name == "escape" and (s.search.hits ~= nil or s.search.error ~= nil) then
				s.search.seq += 1
				s.search.hits, s.search.error, s.search.text = nil, nil, ""
			elseif name == "space" and l then
				local kind = l.kind[r]
				if kind == HEAD then
					l.collapsed = not l.collapsed
				elseif kind == FOLD then
					forcePairs(l, l.a[r], l.b[r])
				elseif kind == MARKED then
					l.shown[l.b[r]] = true
				else
					handled = false
				end
				if handled then
					relayout(s, { l })
				end
			elseif ch == "o" then
				-- Expands every file; unchanged code stays folded (space opens a fold).
				for _, each in s.layouts do
					each.collapsed = false
				end
				relayout(s)
			elseif ch == "O" then
				-- Collapses every file and folds its unchanged code again (folds opened by space or a search).
				for _, each in s.layouts do
					each.collapsed = true
					each.force = nil
				end
				relayout(s)
			elseif ch == "R" and l then
				local h: number? = nil
				if l.kind[r] == PAIR then
					h = hunkAt(l.file, l.a[r])
				elseif l.kind[r] == MARKED then
					h = l.b[r]
				end
				if h == nil then
					s.message = "R marks the hunk under the cursor; put the cursor on a changed row"
				else
					markHunk(s, l.file, h, if markOf(s, l.file.hunks[h].key) == "r" then "s" else "r")
				end
			elseif ch == "r" and l and #l.file.hunks > 0 then
				-- The file's hunks all reviewed: back to seen, else every one reviewed.
				local f = l.file
				local all = true
				for _, h in f.hunks do
					if markOf(s, h.key) ~= "r" then
						all = false
						break
					end
				end
				for h = 1, #f.hunks do
					markHunk(s, f, h, if all then "s" else "r")
				end
			elseif ch == "u" then
				s.since = not s.since
				for _, each in s.layouts do
					each.shown = {}
				end
				relayout(s)
			elseif (ch == "h" or ch == "l" or ch == "H" or ch == "L" or ch == "0" or ch == "$" or name == "left" or name == "right") and l then
				-- Columns a code column shows, for H, L and $: the grid less the mark column, two line-number
				-- columns and a 1-column gap per code column (viewer.css .dv-fb, .dv-s).
				local code = s.cx.cols - 2 - 2 * (math.clamp(#tostring(s.maxLine), 3, 7) + 1)
				local cols = math.max(1, if l.unified then code - 1 else code // 2 - 1)
				local x = s.hx + HSTEP
				if ch == "0" then
					x = 0
				elseif ch == "$" then
					x = s.hx
					if l.kind[r] == PAIR then
						-- The end of the cursor's longer line mid-column. Its width in columns of 0.6em
						-- (viewer.css .dv-t), from lead bytes without decoding: a tab to the next multiple of 4,
						-- U+3000-U+DFFF (CJK, Hangul), U+FF00-U+FF7F (fullwidth forms) and 4-byte characters 1em,
						-- others 1. Mid-column, as glyphs advance a hair off 0.6em and cx.cols can differ from
						-- the width a window draws.
						local w = 0
						for side = 1, 2 do
							local line = if side == 1 then oldAt(l.file, l.a[r]) else newAt(l.file, l.a[r])
							if line > 0 and l.b[r] ~= 3 - side then
								local text = lineText(s, l.file, side, line)
								local n = #text
								if string.find(text, "[\t\128-\255]") then
									n = 0
									for i = 1, #text do
										local b = string.byte(text, i)
										local c = if b == 0xEF then string.byte(text, i + 1) or 0 else 0
										if b == 9 then
											n += 4 - n % 4
										elseif (b >= 0xE3 and b <= 0xED) or b >= 0xF0 or (b == 0xEF and (c == 0xBC or c == 0xBD)) then
											n += 5 / 3
										elseif b < 0x80 or b >= 0xC0 then
											n += 1
										end
									end
								end
								w = math.max(w, n)
							end
						end
						x = math.ceil(w) - cols // 2
					end
				elseif ch == "H" or (name == "left" and k.shift) then
					x = s.hx - cols // 2
				elseif ch == "L" or (name == "right" and k.shift) then
					x = s.hx + cols // 2
				elseif ch == "h" or name == "left" then
					x = s.hx - HSTEP
				end
				x = math.max(0, x)
				if x == s.hx then
					handled = false
				else
					s.hx = x
				end
			elseif ch == "v" and l then
				l.unified = not l.unified
				relayout(s, { l })
				reveal(s)
				s.message = l.file.path .. (if l.unified then ": unified" else ": side by side") .. " (V: every file)"
			elseif ch == "V" then
				s.unified = not s.unified
				pcall(tern.kv.set, "unified", s.unified)
				for _, each in s.layouts do
					each.unified = s.unified
				end
				relayout(s)
				reveal(s)
				s.message = (if s.unified then "every file unified" else "every file side by side") .. " (v: this file)"
			elseif name == "enter" and l and s.dir then
				local f = l.file
				local side = 2
				local line = 1
				if l.kind[r] == PAIR then
					local i = l.a[r]
					local ri = newAt(f, i)
					-- A unified file's old row opens the old side.
					if ri > 0 and l.b[r] ~= 1 then
						side = 2
						line = ri
					else
						side = 1
						line = oldAt(f, i)
					end
				elseif not f.hasNew then
					side = 1
				end
				if (side == 2 and not f.hasNew) or (side == 1 and not f.hasOld) then
					s.message = "this file has no text to open"
				else
					local snapshot = sidePath(s, f, side)
					local target = snapshot
					local root = s.root
					if side == 2 and root then
						local working = root .. "/" .. f.path
						local function read(path: string): string?
							local ok, text = pcall(function(): string
								return tern.fs.read(path)
							end)
							return if ok then text else nil
						end
						if tern.fs.exists(working) and read(working) == read(snapshot) then
							target = working
						end
					end
					s.message = if target == snapshot then "opened " .. (if side == 1 then "the old" else "the new") .. " side's snapshot (the working copy differs)" else nil
					s.cx:open(string.format("%s:%d", target, line))
				end
			elseif ch == "?" then
				s.help = true
			elseif ch == "q" then
				s.cx:exit(0)
			else
				handled = false
			end
		end
		if handled then
			scheduleSeen(s)
		end
		metric("key", { key = k.text or k.name, ms = tern.now() - t0, handled = handled, mem = memKB(s) })
		return handled
	end,

	event = function(s: State, ev: UiEvent, _cx: BlockCx)
		if ev.ev ~= "action" or type(ev.value) ~= "string" then
			return
		end
		if s.seen then
			s.seen:cancel()
		end
		if ev.act == "page" then
			if pageJump(s, if ev.value == "next" then 1 else -1) then
				s.cx:render()
				scheduleSeen(s)
			end
			return
		elseif ev.act ~= "row" then
			return
		end
		local fid = tonumber(string.match(ev.value, "^f(%d+)[hpzmn]%d*[on]?$"))
		local l = if fid then s.layouts[fid] else nil
		if fid == nil or l == nil then
			return
		end
		for r = 1, #l.kind do
			if rowKey(l, r) == ev.value then
				s.cur = s.starts[fid] + r - 1
				break
			end
		end
		scheduleSeen(s)
	end,

	save = function(s: State): any
		return if s.req then { req = s.req } else nil
	end,
}

tern.block.define("diff", viewer)
