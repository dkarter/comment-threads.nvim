local root = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
dofile(vim.fs.joinpath(root, "lua/comment_threads/native.lua")).install(root)
