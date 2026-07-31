-- rtp minimo: solo el plugin y plenary. Nada de config de usuario.
local plugin_root = vim.fn.getcwd()

vim.opt.rtp:prepend(plugin_root)
vim.opt.rtp:prepend(vim.env.PLENARY_PATH or "/opt/plenary")

-- para que los specs puedan hacer require("helpers")
package.path = plugin_root .. "/tests/?.lua;" .. package.path

vim.opt.swapfile = false
vim.g.mapleader = " "

require("plenary.busted")
