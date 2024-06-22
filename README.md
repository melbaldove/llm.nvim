# llm.nvim

A neovim plugin for no frills LLM-assisted programming.


https://github.com/melbaldove/llm.nvim/assets18225174/9bdc2fa1-ade4-48f2-87ce-3019fc323262


### Installation

Before using the plugin, set `OPENROUTER_API_KEY` env var with your api key.

lazy.nvim
```lua
{
    "melbaldove/llm.nvim",
    dependencies = {
        "nvim-neotest/nvim-nio" ,
		"nvim-telescope/telescope.nvim"
        }
}
```

### Usage

**`setup()`**

Configure the plugin. This can be omitted to use the default configuration.

```lua
require('llm').setup({
    -- How long to wait for the request to start returning data.
    timeout_ms = 10000,
    services = {
        openrouter = {
            url = "https://openrouter.ai/api/v1/chat/completions",
            model = "openai/gpt-4-turbo",
            api_key_name = "OPENROUTER_API_KEY",
        }
    }
})
```


**`pick_mode()`**

Opens a fuzzy finder for all available models on openrouter with their additional information like prize, context lengt...

**`prompt()`**

Triggers the LLM assistant. You can pass an optional `replace` flag to replace the current selection with the LLM's response. The prompt is either the visually selected text or the file content up to the cursor if no selection is made.

**`create_llm_md()`**

Creates a new `llm.md` file in the current working directory, where you can write questions or prompts for the LLM.

**Example Bindings**
```lua
vim.keymap.set("n", "<leader>m", function() require("llm").create_llm_md() end)
vim.keymap.set("n", "<leader>ms", function() require("llm").pick_model() end)

vim.keymap.set("n", "<leader>,", function() require("llm").prompt({ replace = false, service = "openrouter" }) end)
vim.keymap.set("v", "<leader>,", function() require("llm").prompt({ replace = false, service = "openrouter" }) end)
vim.keymap.set("v", "<leader>.", function() require("llm").prompt({ replace = true, service = "openrouter" }) end)
```

### Credits

- Special thanks to [yacine](https://twitter.com/i/broadcasts/1kvJpvRPjNaKE) and his ask.md vscode plugin for inspiration!
