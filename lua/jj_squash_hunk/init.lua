--- Squash the hunk under the cursor (or visual selection) from the jj working
--- change into its parent change.
---
--- jj has no staging area, so "I have reviewed this hunk" is expressed by moving
--- it into the parent change with `jj squash -i`. This module automates that for
--- a single hunk from a normal editing buffer: it builds the parent file content
--- plus only the selected hunk(s), then drives `jj squash -i` with a one-shot
--- diff editor that copies the prepared content into `$output`. The editor is a
--- headless `nvim -l` script run by the current nvim binary, so no shell,
--- executable bit or coreutils are involved.
---
--- Diff-editor contract of `jj squash -i --from @ --into @-`:
---   $left   = file version in the destination (@-)
---   $right  = file version in the source (@)
---   $output = desired new content of the destination; whatever is written here
---             gets squashed into the parent, the rest stays in @.

local M = {}

local TITLE = "JJ Squash Hunk"

local config = {
  -- vim.text.diff ctxlen. 0 makes each hunk a maximal block of contiguous changed
  -- lines, matching what gitsigns-style signs show; larger values merge
  -- changes separated by <= 2*ctxlen unchanged lines into one hunk.
  diff_context = 0,
}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

local function run(cmd, opts)
  return vim.system(cmd, vim.tbl_extend("keep", opts or {}, { text = true })):wait()
end

--- Quote a path as a TOML basic string, for embedding in a `--config` value.
local function toml_str(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function to_lf(s)
  return (s:gsub("\r\n", "\n"))
end

--- Split file content into lines, dropping only the final empty element
--- produced by the terminating newline.
local function split_lines(content)
  if content == "" then
    return {}
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Compute hunks between two file contents with the builtin xdiff engine
--- (the same one hunk.nvim uses internally). No subprocess, no text parsing.
---@return { oldstart: integer, oldcount: integer, newstart: integer, newcount: integer, newlines: string[] }[]?
local function diff_hunks(parent_content, current_content)
  local indices = vim.text.diff(parent_content, current_content, {
    result_type = "indices",
    ctxlen = config.diff_context,
  })
  if type(indices) ~= "table" then
    return nil
  end
  local current_lines = split_lines(current_content)
  local hunks = {}
  for _, h in ipairs(indices) do
    local newstart, newcount = h[3], h[4]
    local newlines = {}
    for i = newstart, newstart + newcount - 1 do
      newlines[#newlines + 1] = current_lines[i]
    end
    hunks[#hunks + 1] = {
      oldstart = h[1],
      oldcount = h[2],
      newstart = newstart,
      newcount = newcount,
      newlines = newlines,
    }
  end
  return hunks
end

--- Hunks whose new-side lines overlap [first, last]. Pure deletions
--- (newcount == 0) attach to the line before/after the deleted range,
--- similar to how gitsigns maps deleted hunks.
local function collect_hunks(hunks, first, last)
  local selected = {}
  for _, h in ipairs(hunks) do
    local s, e
    if h.newcount == 0 then
      s, e = math.max(1, h.newstart), h.newstart + 1
    else
      s, e = h.newstart, h.newstart + h.newcount - 1
    end
    if s <= last and e >= first then
      selected[#selected + 1] = h
    end
  end
  return selected
end

--- parent_lines with only the selected hunks applied.
--- xdiff indices semantics: for pure insertions (oldcount == 0) oldstart is
--- the anchor line to insert *after* (0 = top of file); otherwise oldstart is
--- the first replaced/deleted line.
local function apply_hunks(parent_lines, hunks)
  local out = {}
  local pos = 1
  for _, h in ipairs(hunks) do
    if h.oldcount == 0 then
      for i = pos, h.oldstart do
        out[#out + 1] = parent_lines[i]
      end
      pos = h.oldstart + 1
    else
      for i = pos, h.oldstart - 1 do
        out[#out + 1] = parent_lines[i]
      end
      pos = h.oldstart + h.oldcount
    end
    for _, l in ipairs(h.newlines) do
      out[#out + 1] = l
    end
  end
  for i = pos, #parent_lines do
    out[#out + 1] = parent_lines[i]
  end
  return out
end

--- Resolve a revision the same way jj.nvim does (change_id, or commit_id when
--- divergent) so its `jj://<id>/<path>` scratch buffers can be matched.
local function resolve_rev_id(rev, root)
  local res = run({ "jj", "log", "--no-graph", "-r", rev, "-T", "if(divergent, commit_id, change_id)" }, { cwd = root })
  if res.code ~= 0 then
    return nil
  end
  return vim.trim(res.stdout)
end

--- jj.nvim's open_vdiff shows the parent version in a scratch buffer named
--- `jj://<parent_id>/<relpath>`. After a squash the parent was rewritten, so
--- reload that buffer in place and recompute the diff.
local function refresh_jj_diff_views(old_parent_id, relpath, root, file_bufnr)
  if not old_parent_id then
    return
  end
  local prefix = "jj://" .. old_parent_id .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:sub(1, #prefix) == prefix and name:sub(#prefix + 1) == relpath then
      local show = run({ "jj", "file", "show", "-r", "@-", "--", relpath }, { cwd = root })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, show.code == 0 and split_lines(to_lf(show.stdout)) or {})
      vim.bo[buf].modified = false
      local new_parent_id = resolve_rev_id("@-", root)
      if new_parent_id and new_parent_id ~= old_parent_id then
        pcall(vim.api.nvim_buf_set_name, buf, "jj://" .. new_parent_id .. "/" .. relpath)
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.wo[win].diff then
          local wbuf = vim.api.nvim_win_get_buf(win)
          if wbuf == buf or wbuf == file_bufnr then
            vim.api.nvim_win_call(win, function()
              vim.cmd("diffupdate")
            end)
          end
        end
      end
    end
  end
end

--- Squash every hunk overlapping the 1-based inclusive line range [first, last]
--- into the parent change. Mapping to `:JJSquashHunk` covers both modes, since a
--- command without a range uses the cursor line and a visual `:` uses the
--- selection.
---@param first integer
---@param last integer
function M.squash_lines(first, last)
  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  -- The URI-scheme check catches virtual buffers like jj.nvim's `jj://<id>/<path>`
  -- revision views, which deliberately use buftype="".
  if bufname == "" or vim.bo[bufnr].buftype ~= "" or bufname:match("^%w[%w+-.]*://") then
    return notify("Buffer is not a normal file.", vim.log.levels.WARN)
  end

  -- Resolve symlinks up front: vim.fs.relpath() compares literal prefixes and
  -- returns nil when one side is /var/... and the other /private/var/...
  local filepath = vim.uv.fs_realpath(bufname) or bufname
  local root = vim.fs.root(filepath, ".jj")
  if not root then
    return notify("Not inside a jj repository.", vim.log.levels.WARN)
  end

  -- Note: nvim 0.12 signature is relpath(base, target).
  local relpath = vim.fs.relpath(root, filepath)
  if not relpath then
    return notify("Cannot resolve path relative to the jj root.", vim.log.levels.ERROR)
  end

  -- jj snapshots the file on disk, so pending edits must be saved first.
  if vim.bo[bufnr].modified then
    local ok, err = pcall(vim.cmd, "write")
    if not ok then
      return notify("Failed to save buffer: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  local tmpdir = vim.fn.tempname()
  vim.fn.mkdir(tmpdir, "p")

  -- Destination (@-) version; a missing file means it was added in @.
  -- text=false because vim.system's text mode rewrites \r\n to \n, which would
  -- hide the parent's real line endings.
  local show = run({ "jj", "file", "show", "-r", "@-", "--", relpath }, { cwd = root, text = false })
  if show.code ~= 0 and not show.stderr:match("No such path") then
    vim.fn.delete(tmpdir, "rf")
    return notify("jj file show failed:\n" .. vim.trim(show.stderr), vim.log.levels.ERROR)
  end
  local parent_raw = show.code == 0 and show.stdout or ""
  -- jj can store LF while the working copy uses CRLF (working-copy.eol-conversion);
  -- diffing the raw bytes would then mark every line as changed.
  local eol = parent_raw:find("\r\n", 1, true) and "\r\n" or "\n"
  local parent_content = to_lf(parent_raw)
  local parent_lines = split_lines(parent_content)

  -- Read the file from disk (== buffer content after the save above) so the
  -- squash matches exactly what jj will snapshot.
  local fh = io.open(filepath, "rb")
  if not fh then
    vim.fn.delete(tmpdir, "rf")
    return notify("Cannot read file: " .. filepath, vim.log.levels.ERROR)
  end
  local current_content = to_lf(fh:read("*a") or "")
  fh:close()

  local hunks = diff_hunks(parent_content, current_content)
  if not hunks then
    vim.fn.delete(tmpdir, "rf")
    return notify("Failed to compute diff.", vim.log.levels.ERROR)
  end
  if #hunks == 0 then
    vim.fn.delete(tmpdir, "rf")
    return notify("No changes between the parent change and this file.", vim.log.levels.WARN)
  end

  local selected = collect_hunks(hunks, first, last)
  if #selected == 0 then
    vim.fn.delete(tmpdir, "rf")
    return notify("No changed hunk under the cursor.", vim.log.levels.WARN)
  end

  -- Prepared content: parent with only the selected hunks applied, in the
  -- parent's own line endings. writefile() writes a Lua string as a blob, so the
  -- bytes land unmodified.
  local prepared = tmpdir .. "/prepared"
  local prepared_lines = apply_hunks(parent_lines, selected)
  vim.fn.writefile(#prepared_lines > 0 and (table.concat(prepared_lines, eol) .. eol) or "", prepared)

  -- One-shot diff editor: headless nvim copies the prepared file into $output.
  -- arg[1..3] are $left/$right/$output; jj passes arg[4]/arg[5] through verbatim.
  local script = tmpdir .. "/diff-editor.lua"
  vim.fn.writefile({
    'local dest = arg[3] .. "/" .. arg[5]',
    'vim.fn.mkdir(vim.fn.fnamemodify(dest, ":h"), "p")',
    "assert(vim.uv.fs_copyfile(arg[4], dest))",
    "os.exit(0)",
  }, script)

  -- Captured before the squash: afterwards @- points to a rewritten commit and
  -- jj.nvim's vdiff scratch buffer still carries the old id in its name.
  local old_parent_id = resolve_rev_id("@-", root)

  local sq = run({
    "jj",
    "squash",
    "-i",
    "--from",
    "@",
    "--into",
    "@-",
    "--config",
    "ui.diff-editor=["
      .. table.concat({
        toml_str(vim.v.progpath),
        '"-l"',
        toml_str(script),
        '"$left"',
        '"$right"',
        '"$output"',
        toml_str(prepared),
        toml_str(relpath),
      }, ",")
      .. "]",
    "--config",
    "ui.diff-instructions=false",
    "--",
    relpath,
  }, { cwd = root })

  vim.fn.delete(tmpdir, "rf")

  if sq.code ~= 0 then
    return notify("jj squash failed:\n" .. vim.trim(sq.stderr), vim.log.levels.ERROR)
  end

  refresh_jj_diff_views(old_parent_id, relpath, root, bufnr)
  pcall(function()
    require("gitsigns").refresh(bufname)
  end)
  notify(string.format("Squashed %d hunk(s) of %s into the parent change.", #selected, relpath))
end

--- Merge {opts} into the defaults. The plugin registers no keymaps; map
--- `:JJSquashHunk` or `M.squash_lines()` wherever you like.
---@param opts? { diff_context?: integer }
function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

return M
