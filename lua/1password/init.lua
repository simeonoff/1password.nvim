-- 1password.nvim - A Neovim plugin for 1Password integration
-- Author: Simeon Simeonoff
-- License: MIT
-- Version: 0.0.1

-- Check for plenary dependency
local has_plenary, Job = pcall(require, 'plenary.job')

if not has_plenary then error('1password.nvim requires plenary.nvim. Please install it using your plugin manager.') end

--- @class OnePassword
--- @field private _loaded boolean Whether the plugin has been loaded
local M = {
  _loaded = false,
  _config = {
    notify_level = vim.log.levels.INFO,
    auto_load = false,
    secrets = {}, -- Format: { var_name = "Vault/Item/Field" }
    env_vars = {}, -- Format: { ENV_VAR_NAME = "var_name" } or { ENV_VAR_NAME = "Vault/Item/Field" }
    debug = false, -- Enable debug output
    disable_swap_files = false,
  },
}

--- Send a notification with appropriate level
--- @param message string The notification message
--- @param level number|nil The notification level (defaults to INFO)
local function notify(message, level)
  level = level or M._config.notify_level
  vim.schedule(function() vim.notify(message, level, { title = '1Password.nvim' }) end)
end

--- Debug output function
--- @param ... any
local function debug_print(...)
  if not M._config.debug then return end

  local args = { ... }
  local msg = ''
  for _, v in ipairs(args) do
    msg = msg .. tostring(v) .. ' '
  end

  vim.schedule(function() notify('DEBUG: ' .. msg, vim.log.levels.DEBUG) end)
end

--- Validate and sanitize a 1Password secret path
--- @param secret_path string The path in format "Vault/Item/Field"
--- @return boolean is_valid Whether the path is valid
--- @return string? error_message Error message if invalid
local function validate_path(secret_path)
  if type(secret_path) ~= 'string' then return false, 'Secret path must be a string' end

  if not string.match(secret_path, '^[%w-_]+/[%w-_]+/[%w-_ ]+$') then
    return false, "Invalid secret path format. Use 'Vault/Item/Field'"
  end

  return true, nil
end

--- Check if 1Password CLI is available in PATH and authenticated asynchronously
--- @param callback function Function to call with the result (boolean, string|nil)
local function check_op_cli(callback)
  -- First check if the CLI is installed
  Job
    :new({
      command = 'which',
      args = { 'op' },
      on_exit = function(_, return_val)
        if return_val ~= 0 then
          callback(false, '1Password CLI (op) not found in PATH')
          return
        end

        -- Then check if the CLI is authenticated by running a simple command
        Job
          :new({
            command = 'op',
            args = { 'account', 'list', '--format=json' },
            on_exit = function(j, auth_return_val)
              if auth_return_val == 0 then
                callback(true, nil)
              elseif auth_return_val == 2 then
                callback(false, "Authentication required for 1Password CLI. Please run 'op signin' in your terminal.")
              elseif auth_return_val == 3 then
                callback(false, 'Authentication failed for 1Password CLI. Please check your credentials.')
              else
                local stderr = table.concat(j:stderr_result(), '\n')
                callback(false, 'Error checking 1Password CLI authentication: ' .. stderr)
              end
            end,
          })
          :start()
      end,
    })
    :start()
end

--- Retrieve a secret from 1Password asynchronously
--- @param secret_path string The path in format "Vault/Item/Field"
--- @param callback function Function to call with the result (string|nil)
local function get_secret(secret_path, callback)
  local valid, err_msg = validate_path(secret_path)
  if not valid and err_msg then
    notify(err_msg, vim.log.levels.ERROR)
    vim.schedule(function() callback(nil) end)
    return
  end

  debug_print('Retrieving secret for:', secret_path)

  -- Create a job to run the 1Password CLI command
  local job = Job:new({
    command = 'op',
    args = { 'read', 'op://' .. secret_path },
    on_stdout = function(_, data) debug_print('Received stdout data of length:', #data) end,
    on_stderr = function(_, data) debug_print('Received stderr data:', data) end,
    on_exit = function(j, return_val)

      -- Handle different exit codes from 1Password CLI
      if return_val ~= 0 then
        local stderr = table.concat(j:stderr_result(), '\n')

        -- Handle specific exit codes
        if return_val == 2 then
          notify(
            'Authentication required for 1Password CLI. Please run "op signin" in your terminal.',
            vim.log.levels.ERROR
          )
        elseif return_val == 3 then
          notify('Authentication failed for 1Password CLI. Please check your credentials.', vim.log.levels.ERROR)
        else
          notify('Failed to get secret for ' .. secret_path .. ': ' .. stderr, vim.log.levels.WARN)
        end

        callback(nil)
        return
      end

      local result = table.concat(j:result(), '\n')
      debug_print('Retrieved secret of length:', #result)

      if result == '' then
        notify('Empty result for secret: ' .. secret_path, vim.log.levels.WARN)
        callback(nil)
        return
      end

      callback(result)
    end,
  })

  -- Start the job
  job:start()
end

--- Set an environment variable in Neovim's process
--- @param env_var string The environment variable name
--- @param value string The value to set
--- @return boolean success Whether the variable was set successfully
local function set_env_var(env_var, value)
  if type(env_var) ~= 'string' or type(value) ~= 'string' then return false end

  vim.env[env_var] = value
  debug_print('Set environment variable:', env_var)
  return true
end

--- Load a single secret into a Neovim global variable asynchronously
--- @param var_name string The variable name to set (without vim.g)
--- @param secret_path string The 1Password path
--- @param callback function|nil Optional callback function(success)
function M.load_secret(var_name, secret_path, callback)
  callback = callback or function(_) end

  debug_print('Loading secret for', var_name, 'from', secret_path)

  get_secret(secret_path, function(secret_value)
    if secret_value then
      -- Set as a global Vim variable
      vim.g[var_name] = secret_value
      notify('Loaded secret for: ' .. var_name, vim.log.levels.INFO)
      callback(true)
    else
      callback(false)
    end
  end)
end

--- Load environment variables with values from 1Password
--- @param env_vars table<string, string>|nil Map of env var names to either var_names or secret paths
--- @param callback function|nil Optional callback function(success)
function M.load_env_vars(env_vars, callback)
  env_vars = env_vars or M._config.env_vars
  callback = callback or function(_) end

  -- If no env vars to load, return immediately
  if not env_vars or vim.tbl_isempty(env_vars) then
    notify('No environment variables configured to load', vim.log.levels.WARN)
    callback(false)
    return
  end

  -- Count for tracking completion
  local total_vars = vim.tbl_count(env_vars)
  local loaded_count = 0
  local success_count = 0

  -- Process each environment variable
  for env_var_name, source in pairs(env_vars) do
    -- If the source has a valid 1Password path format, load directly
    if validate_path(source) then
      vim.schedule(
        function()
          notify(
            'Loading environment variable ' .. env_var_name .. ' from 1Password path: ' .. source,
            vim.log.levels.INFO
          )
        end
      )

      -- Load directly from 1Password
      get_secret(source, function(secret_value)
        if secret_value then
          vim.schedule(function()
            if set_env_var(env_var_name, secret_value) then success_count = success_count + 1 end
            loaded_count = loaded_count + 1

            -- Check if all vars are loaded
            if loaded_count == total_vars then
              if success_count == total_vars then
                notify('Successfully loaded all environment variables', vim.log.levels.INFO)
              else
                notify('Loaded ' .. success_count .. '/' .. total_vars .. ' environment variables', vim.log.levels.WARN)
              end
              callback(success_count == total_vars)
            end
          end)
        else
          vim.schedule(function()
            loaded_count = loaded_count + 1
            if loaded_count == total_vars then
              notify('Loaded ' .. success_count .. '/' .. total_vars .. ' environment variables', vim.log.levels.WARN)
              callback(success_count == total_vars)
            end
          end)
        end
      end)
    else
      -- Check if it references a variable we've already loaded
      vim.schedule(function()
        if vim.g[source] then
          if set_env_var(env_var_name, vim.g[source]) then
            success_count = success_count + 1
            notify('Set environment variable ' .. env_var_name .. ' from ' .. source, vim.log.levels.INFO)
          end
        else
          notify(
            'Cannot set environment variable ' .. env_var_name .. ': source variable ' .. source .. ' not found',
            vim.log.levels.WARN
          )
        end

        loaded_count = loaded_count + 1
        if loaded_count == total_vars then
          if success_count == total_vars then
            notify('Successfully loaded all environment variables', vim.log.levels.INFO)
          else
            notify('Loaded ' .. success_count .. '/' .. total_vars .. ' environment variables', vim.log.levels.WARN)
          end
          callback(success_count == total_vars)
        end
      end)
    end
  end
end

--- Load multiple secrets from 1Password into Neovim global variables asynchronously
--- @param secrets table<string, string>|nil Map of variable names to 1Password paths (uses config if nil)
--- @param callback function|nil Optional callback function(success)
function M.load_secrets(secrets, callback)
  secrets = secrets or M._config.secrets
  callback = callback or function(_) end

  -- If no secrets to load, return immediately
  if not secrets or vim.tbl_isempty(secrets) then
    notify('No secrets configured to load', vim.log.levels.WARN)
    callback(false)
    return
  end

  -- Check if 1Password CLI is available and authenticated
  check_op_cli(function(cli_available, error_message)
    if not cli_available then
      notify(error_message or '1Password CLI error', vim.log.levels.ERROR)
      callback(false)
      return
    end

    -- Count successful loads
    local total_secrets = vim.tbl_count(secrets)
    local loaded_count = 0
    local success_count = 0

    -- Process all secrets asynchronously
    for var_name, secret_path in pairs(secrets) do
      M.load_secret(var_name, secret_path, function(success)
        loaded_count = loaded_count + 1
        if success then success_count = success_count + 1 end

        -- When all secrets are processed, call the callback
        if loaded_count == total_secrets then
          local all_success = success_count == total_secrets
          if all_success then
            notify('Successfully loaded all secrets', vim.log.levels.INFO)
          else
            notify('Loaded ' .. success_count .. '/' .. total_secrets .. ' secrets', vim.log.levels.WARN)
          end
          callback(all_success)
        end
      end)
    end
  end)
end

--- Setup the plugin with user configuration
--- @param opts table|nil User configuration options
--- @return table The plugin instance
function M.setup(opts)
  if M._loaded then return M end

  if not has_plenary then
    notify('1password.nvim requires plenary.nvim. Please install it using your plugin manager.', vim.log.levels.ERROR)
    return M
  end

  opts = opts or {}
  M._config = vim.tbl_deep_extend('force', M._config, opts)

  M._loaded = true

  if M._config.auto_load and next(M._config.secrets) then
    vim.api.nvim_create_autocmd('VimEnter', {
      callback = function()
        M.load_secrets(nil, function(_) end)
      end,
      group = vim.api.nvim_create_augroup('OnePasswordAutoload', { clear = true }),
    })
  end

  if M._config.auto_load and next(M._config.env_vars) then
    vim.api.nvim_create_autocmd('VimEnter', {
      callback = function()
        M.load_env_vars(nil, function(_) end)
      end,
      group = vim.api.nvim_create_augroup('OnePasswordAutoload', { clear = true }),
    })
  end

  vim.api.nvim_create_user_command('OnePasswordLoad', function()
    M.load_secrets(nil, function(_) end)
  end, {
    desc = 'Load all configured 1Password secrets',
  })

  vim.api.nvim_create_user_command('OnePasswordSecret', function(o)
    if #o.fargs < 2 then
      notify('Usage: OnePasswordSecret <var_name> <vault/item/field>', vim.log.levels.ERROR)
      return
    end
    M.load_secret(o.fargs[1], o.fargs[2], function(_) end)
  end, {
    desc = 'Load a single 1Password secret',
    nargs = '+',
    complete = function(_, _, _)
      return {} -- Could be extended to provide completion from known vaults
    end,
  })

  vim.api.nvim_create_user_command('OnePasswordEnv', function(o)
    if #o.fargs < 2 then
      notify('Usage: OnePasswordEnv <ENV_VAR_NAME> <source>', vim.log.levels.ERROR)
      return
    end

    local env_vars = { [o.fargs[1]] = o.fargs[2] }
    M.load_env_vars(env_vars, function(_) end)
  end, {
    desc = 'Set an environment variable from a 1Password secret or loaded variable',
    nargs = '+',
    complete = function(_, _, _) return {} end,
  })

  -- Optionally disable swap files for security
  if M._config.disable_swap_files then
    vim.opt.swapfile = false
    notify('Disabled swap files for security with 1password.nvim', vim.log.levels.INFO)
  end

  return M
end

return M
