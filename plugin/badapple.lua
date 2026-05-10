if vim.g.loaded_badapple_nvim then
    return
end
vim.g.loaded_badapple_nvim = true

local badapple = require("badapple")

vim.api.nvim_create_user_command("BadAppleStart", badapple.start, {
    desc = "Start Bad Apple braille animation",
})

vim.api.nvim_create_user_command("BadAppleStop", badapple.stop, {
    desc = "Stop Bad Apple braille animation",
})
