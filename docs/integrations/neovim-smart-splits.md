# Neovim Smart-Splits Integration

Mistty supports seamless pane navigation with neovim's
[smart-splits.nvim](https://github.com/mrjones2014/smart-splits.nvim) plugin.

## How It Works

- **Ctrl-H/J/K/L** navigates between Mistty panes
- When the active pane is running neovim, Mistty passes the keypress through
- smart-splits.nvim handles navigation within neovim splits
- When neovim is at its boundary, smart-splits calls back to Mistty via CLI

## Neovim Configuration

Add to your neovim config:

```lua
require('smart-splits').setup({
  at_edge = function(opts)
    local dir_map = {
      left = 'left',
      right = 'right',
      up = 'up',
      down = 'down',
    }
    os.execute('mistty-cli pane focus --direction ' .. dir_map[opts.direction])
  end
})

-- Keymaps
vim.keymap.set('n', '<C-h>', require('smart-splits').move_cursor_left)
vim.keymap.set('n', '<C-j>', require('smart-splits').move_cursor_down)
vim.keymap.set('n', '<C-k>', require('smart-splits').move_cursor_up)
vim.keymap.set('n', '<C-l>', require('smart-splits').move_cursor_right)
```

## Requirements

- `mistty-cli` must be on your PATH
