local M = {}

-- Extract the tree prefix (if any) from a line
local function get_tree_prefix(line)
  local _, prefix_len = line:find("─ ", 1, true)
  if prefix_len then
    return line:sub(1, prefix_len)
  else
    return ""
  end
end

-- Add a filetype icon to a line
local function line_with_icon(line)
  line = line:gsub("[\r\n]+$", "") -- Trailing newlines mess with filetype detection

  local tree_prefix = get_tree_prefix(line)
  local url = line:sub(#tree_prefix + 1)
  local file = File({
    url = Url(url),
    cha = Cha {
      mode = tonumber(url:sub(-1) == "/" and "40700" or "100644", 8),
      kind = url:sub(-1) == "/" and 1 or 0, -- For Yazi <25.9.x compatibility
    }
  })
  local icon = th.icon:match(file)

  if icon then
    line =  ui.Line { tree_prefix, ui.Span(icon.text .. " "):style(icon.style), url }
  end

  return line
end

function M:peek(job)
  local cmd = Command("ouch"):arg("l")
  if not job.args.list_view then
    cmd:arg("-t")
  end
  cmd:arg({ "-y", tostring(job.file.url) })
      :stdout(Command.PIPED)
      :stderr(Command.PIPED)

  local child = cmd:spawn()
  local limit = job.area.h
  local archive_icon = job.args.archive_icon or "\u{1f4c1} "
  local file_name = string.match(tostring(job.file.url), ".*[/\\](.*)")
  local lines = { string.format(" %s%s", archive_icon, file_name) }
  local num_skip = 0
  repeat
    local line, event = child:read_line()
    if event == 1 then
      ya.err(tostring(event))
    elseif event ~= 0 then
      break
    end

    if line:find('Archive', 1, true) ~= 1 and line:find('[INFO]', 1, true) ~= 1 then
      if num_skip >= job.skip then
        if job.args.show_file_icons then
          if line:find ('[ERROR]', 1, true) == 1 then
            -- On error, disable file icons for the rest of the output
            job.args.show_file_icons = false
          elseif line:find ('[WARNING]', 1, true) ~= 1 then
            -- Show icons for non-warning lines only
            line = line_with_icon(line)
          end
        end

        line = ui.Line { " ", line } -- One space padding
        table.insert(lines, line)
      else
        num_skip = num_skip + 1
      end
    end
  until #lines >= limit

  child:start_kill()
  if job.skip > 0 and #lines < limit then
    ya.emit(
      "peek",
      { tostring(math.max(0, job.skip - (limit - #lines))), only_if = tostring(job.file.url), upper_bound = "" }
    )
  else
    ya.preview_widget(job, { ui.Text(lines):area(job.area) })
  end
end

function M:seek(job)
  local h = cx.active.current.hovered
  if h and h.url == job.file.url then
    local step = math.floor(job.units * job.area.h / 10)
    ya.emit("peek", {
      math.max(0, cx.active.preview.skip + step),
      only_if = tostring(job.file.url),
    })
  end
end

-- Check if file exists
local function file_exists(name)
  local f = io.open(name, "r")
  if f ~= nil then
    io.close(f)
    return true
  else
    return false
  end
end

-- Get the files that need to be compressed and infer a default archive name
local get_compression_target = ya.sync(function()
  local tab = cx.active
  local default_name
  local paths = {}
  if #tab.selected == 0 then
    if tab.current.hovered then
      local name = tab.current.hovered.name
      default_name = name
      table.insert(paths, name)
    else
      return
    end
  else
    default_name = tab.current.cwd.name
    for _, file in pairs(tab.selected) do
      table.insert(paths, tostring(file.url))
    end
    -- The compression targets are aquired, now unselect them
    ya.emit("escape", {})
  end
  return paths, default_name
end)

local function invoke_compress_command(paths, name)
  if name:sub(1, 1) == "-" then
    name = "./" .. name
  end

  local cmd_output, err_code = Command("ouch")
      :arg({ "c", "-y", "--" })
      :arg(paths)
      :arg(name)
      :stderr(Command.PIPED)
      :output()
  if err_code ~= nil then
    ya.notify({
      title = "Failed to run ouch command",
      content = "Status: " .. err_code,
      timeout = 5.0,
      level = "error",
    })
  elseif not cmd_output.status.success then
    ya.notify({
      title = "Compression failed: status code " .. cmd_output.status.code,
      content = cmd_output.stderr,
      timeout = 5.0,
      level = "error",
    })
  end
end

---------------------------------------------------------------------------
-- Decompression
---------------------------------------------------------------------------

-- Get the archives to extract: the selected files, or the hovered file if
-- nothing is selected. Returns full paths, and whether they came from a selection.
local get_extraction_targets = ya.sync(function()
  local tab = cx.active
  local paths = {}
  local from_selection = #tab.selected > 0
  if from_selection then
    for _, file in pairs(tab.selected) do
      table.insert(paths, tostring(file.url))
    end
  elseif tab.current.hovered then
    table.insert(paths, tostring(tab.current.hovered.url))
  end
  return paths, from_selection
end)

-- Split a full path into its directory and file name
local function split_path(path)
  local dir, name = path:match("^(.*)[/\\]([^/\\]+)$")
  if not name then
    return ".", path
  end
  if dir == "" then
    dir = "/"
  end
  return dir, name
end

-- Run ouch from `cwd` (ouch resolves its output paths relative to it).
-- stdin is closed so ouch can never block on a prompt we can't see.
local function run_ouch(args, cwd)
  return Command("ouch")
      :arg(args)
      :cwd(cwd)
      :stdin(Command.NULL)
      :stdout(Command.PIPED)
      :stderr(Command.PIPED)
      :output()
end

local function notify_error(title, content)
  ya.notify({
    title = title,
    content = content,
    timeout = 6.0,
    level = "error",
  })
end

local function confirm(title)
  local value, event = ya.input({
    title = title,
    pos = { "top-center", y = 3, w = 60 },
  })
  return event == 1 and value:lower() == "y"
end

-- From the output of `ouch l`, collect the files that already exist in `dir`.
-- Directories (entries ending in "/") are skipped, since merging into an
-- existing directory is normal and only files get overwritten.
local function find_existing_files(listing, dir)
  local existing = {}
  local first = true
  for line in (listing or ""):gmatch("[^\r\n]+") do
    if first and line:find("Archive: ", 1, true) == 1 then
      -- header line
    elseif line:sub(-1) ~= "/" then
      local f = io.open(dir .. "/" .. line, "r")
      if f then
        f:close()
        table.insert(existing, line)
      end
    end
    first = false
  end
  return existing
end

local function overwrite_title(existing)
  if #existing == 1 then
    return string.format('Overwrite "%s"? (y/N)', existing[1])
  end
  return string.format('Overwrite "%s" and %d more? (y/N)', existing[1], #existing - 1)
end

-- Report a failed ouch run. Returns true if everything was fine.
local function check_result(output, err, name)
  if err ~= nil then
    notify_error("Failed to run ouch command", "Status: " .. tostring(err))
    return false
  elseif not output.status.success then
    notify_error("Extraction failed: " .. name, output.stderr)
    return false
  end
  return true
end

-- Extract one archive. Never overwrites anything without asking first.
local function extract_one(archive, here)
  local dir, name = split_path(archive)

  if here then
    -- `ouch d --here` overwrites existing files without asking, so look
    -- inside the archive first and ask before touching anything.
    local list, list_err = run_ouch({ "l", "-y", archive }, dir)
    if list_err ~= nil then
      notify_error("Failed to run ouch command", "Status: " .. tostring(list_err))
      return
    end

    if list.status.success then
      local existing = find_existing_files(list.stdout, dir)
      if #existing > 0 and not confirm(overwrite_title(existing)) then
        return
      end
      -- Conflicts are resolved (or there are none), so overwriting is intended
      local output, err = run_ouch({ "d", "-y", "--here", archive }, dir)
      check_result(output, err, name)
      return
    end

    -- Single-file compressed files (foo.txt.gz) can't be listed. ouch checks
    -- for conflicts itself in that case, handled below. Any other listing
    -- failure means we can't tell what would be overwritten, so don't extract.
    if not (list.stderr or ""):find("Only archives can have their contents listed", 1, true) then
      notify_error("Cannot read " .. name, list.stderr)
      return
    end
  end

  -- Without -y/-n and without a terminal, ouch refuses to overwrite and
  -- tells us so. Ask the user, and only then retry with -y.
  local args = here and { "d", "--here", archive } or { "d", archive }
  local output, err = run_ouch(args, dir)
  if err == nil and output.status.success then
    return
  end

  local stderr = output and output.stderr or ""
  if err == nil and stderr:find("resolve file conflict", 1, true) then
    local target = stderr:match('Handle file conflict for "(.-)":') or name
    if confirm(string.format('"%s" exists. Overwrite? (y/N)', target)) then
      args[#args + 1] = "-y"
      local output2, err2 = run_ouch(args, dir)
      check_result(output2, err2, name)
    end
    return
  end

  check_result(output, err, name)
end

local function extract(job)
  ya.emit("escape", { visual = true })

  local paths, from_selection = get_extraction_targets()
  if #paths == 0 then
    return
  end

  local here = job.args[1] == "extract-here"
  for _, path in ipairs(paths) do
    extract_one(path, here)
  end

  if from_selection then
    ya.emit("escape", {})
  end
end

function M:entry(job)
  -- `plugin ouch extract` (into a subfolder) or `plugin ouch extract-here`
  if job.args[1] == "extract" or job.args[1] == "extract-here" then
    return extract(job)
  end

  local default_fmt = job.args[1]
  if default_fmt == nil then
    default_fmt = "zip"
  end

  ya.emit("escape", { visual = true })

  -- Get the files that need to be compressed and infer a default archive name
  local paths, default_name = get_compression_target()

  -- Get archive name from user
  local output_name, name_event = ya.input({
    title = "Create archive:",
    value = default_name .. "." .. default_fmt,
    pos = { "top-center", y = 3, w = 40 },
  })
  if name_event ~= 1 then
    return
  end

  -- Get confirmation if file exists
  if file_exists(output_name) then
    local confirm, confirm_event = ya.input({
      title = "Overwrite " .. output_name .. "? (y/N)",
      pos = { "top-center", y = 3, w = 40 },
    })
    if not (confirm_event == 1 and confirm:lower() == "y") then
      return
    end
  end

  invoke_compress_command(paths, output_name)
end

return M
