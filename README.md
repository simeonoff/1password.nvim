# 1password.nvim

A Neovim plugin for 1Password integration. This plugin allows you to securely load secrets from 1Password into Neovim without exposing them in your configuration files.

## Overview

This plugin solves the common problem of storing sensitive credentials like API keys in Neovim configuration files. Instead of hardcoding these values, you can reference them from 1Password and load them at runtime.

## Prerequisites

- 1Password CLI (`op`) installed and in your PATH
- plenary.nvim plugin installed
- 1Password account and vault with your secrets

## Installation

### Using packer.nvim

```lua
use {
  "simeonoff/1password.nvim",
  requires = { "nvim-lua/plenary.nvim" }
}
```

### Using lazy.nvim

```lua
{
  "simeonoff/1password.nvim",
  dependencies = { "nvim-lua/plenary.nvim" }
  event = "VeryLazy",
}
```

## Basic Usage

```lua
require('1password').setup({
  secrets = {
    -- Format: <variable_name> = "<vault>/<item>/<field>"
    anthropic_api_key = "Personal/Anthropic/API key", 
  }
})
```

This will load the "API key" field from the "Anthropic" item in your "Personal" vault into `vim.g.anthropic_api_key`.

## Configuration Options

```lua
require('1password').setup({
  -- Variables to load into vim.g
  secrets = {
    anthropic_api_key = "Personal/Anthropic/API key",
    github_token = "Personal/GitHub/Token",
  },
  
  -- Environment variables to set (vim.env)
  env_vars = {
    -- Load directly from 1Password
    GITHUB_TOKEN = "Personal/GitHub/Token",
    
    -- Reference an already loaded secret
    ANTHROPIC_API_KEY = "anthropic_api_key", 
  },
  
  -- Automatically load secrets when Neovim starts (default: false)
  auto_load = true,
  
  -- Notification level for messages
  notify_level = vim.log.levels.INFO,
  
  -- Timeout for operations in milliseconds (default: 10000)
  timeout_ms = 5000,
  
  -- Enable debug output (default: false)
  debug = false,
  
  -- Disable swap files for security (default: false)
  disable_swap_files = true,
})
```

## Public API

### Load Secrets

Load secrets into Neovim global variables:

```lua
require('1password').load_secrets({
  api_key = "Personal/API/Key",
  github_token = "Personal/GitHub/Token"
}, function(success)
  -- Optional callback
  if success then
    print("Secrets loaded successfully")
  end
end)
```

### Load a Single Secret

```lua
require('1password').load_secret(
  "api_key",           -- Variable name
  "Personal/API/Key",  -- 1Password path
  function(success)
    -- Optional callback
    if success then
      print("Secret loaded successfully")
    end
  end
)
```

### Load Environment Variables

```lua
require('1password').load_env_vars({
  GITHUB_TOKEN = "Personal/GitHub/Token",
  API_KEY = "Personal/API/Key",
}, function(success)
  -- Optional callback
  if success then
    print("Environment variables set")
  end
end)
```

## User Commands

- `:OnePasswordLoad` - Load all configured secrets
- `:OnePasswordSecret <var_name> <vault/item/field>` - Load a specific secret
- `:OnePasswordEnv <ENV_VAR> <source>` - Set an environment variable

## Authentication

The plugin uses the 1Password CLI's authentication. For best results:

1. Sign in to 1Password CLI before starting Neovim:
   ```
   eval $(op signin)
   ```
2. Start Neovim from the same terminal session

## Security Considerations

When using this plugin, be aware of these security implications:

1. **Memory Exposure** - Secrets are stored in memory as Vim global variables and environment variables, which could potentially be accessed by other plugins.

2. **Swap Files** - By default, the plugin does not disable swap files unless you enable the `disable_swap_files` option. If swap files are enabled, your secrets might be written to disk.

3. **Clipboard Risk** - Be careful not to copy sensitive values to your clipboard, as clipboard managers might store them.

4. **Terminal History** - When using user commands like `:OnePasswordSecret`, be aware that the commands might be saved in Neovim's command history.

5. **Plugin Conflicts** - Other plugins might have access to your loaded secrets if they can read Vim global variables or environment variables.

6. **Debugging** - Enabling the debug mode will display sensitive information in notifications, which should be avoided in shared environments.

To minimize risks:

- Only load secrets when absolutely necessary (consider setting `auto_load = false` and using commands manually)
- Use environment variables instead of global variables when possible
- Consider enabling the `disable_swap_files` option
- Use the plugin in trusted environments only

## License

MIT
