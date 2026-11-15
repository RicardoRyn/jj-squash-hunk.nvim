-- Auto-sourced on startup; keep this file cheap. The module is only required
-- when the command actually runs.
if vim.g.loaded_jj_squash_hunk then
  return
end
vim.g.loaded_jj_squash_hunk = true

vim.api.nvim_create_user_command("JJSquashHunk", function(opts)
  require("jj_squash_hunk").squash_lines(opts.line1, opts.line2)
end, {
  range = true,
  desc = "Squash hunk(s)",
})
