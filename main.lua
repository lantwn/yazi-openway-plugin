-- open-with.yazi
--
-- Add every desktop application that can open the selected files to yazi's
-- native "Open with" picker.  The apps are discovered through GIO (the same
-- data Nautilus uses) and injected as temporary opener rules at runtime.
--
-- Requirements:
--   * yazi >= 26.5.6 (dynamic rt.open / rt.opener Lua API)
--   * python3 + PyGObject (Gio, GioUnix)
--
-- Install this directory as:
--   ~/.config/yazi/plugins/open-with.yazi

local PREFIX = "openwith_"
local PLUGIN = "open-with"
local PYTHON = os.getenv("OPEN_WITH_PYTHON") or "python3"

local DEBUG = os.getenv("OPEN_WITH_DEBUG") == "1"

local function dbg(...)
	if not DEBUG then
		return
	end
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...))
	end
	ya.dbg(table.concat(parts, " "))
end

local TYPE_PATS = {
	"text",
	"image",
	"video",
	"application",
	"audio",
	"font",
	"inode",
	"message",
	"model",
	"vector",
	"biosig",
	"chemical",
	"rinex",
	"x%-epoc",
}

local function helper_path()
	return tostring(rt.path.config_dir) .. "/plugins/" .. PLUGIN .. ".yazi/assets/open-with-gio"
end

local function strip_temp(use)
	local out = {}
	for _, name in ipairs(use or {}) do
		if not name:match("^" .. PREFIX) then
			out[#out + 1] = name
		end
	end
	return out
end

-- Keep this in sync with yazi's own mime.local preset: yazi removes the `x-`
-- and `vnd.` prefixes, and uses inode/empty for empty files.  GIO uses
-- shared-mime-info names instead (e.g. application/x-zerosize), so the two
-- must not be mixed when looking up yazi's open rules.
local function normalize_mime(line)
	for _, pat in ipairs(TYPE_PATS) do
		local typ, sub = line:match(string.format("(%s/)([+-.a-zA-Z0-9]+)%%s*$", pat))
		if sub then
			if line:find(typ .. sub, 1, true) == 1 then
				return (typ:gsub("^x%-", "", 1) .. sub:gsub("^x%-", "", 1):gsub("^vnd%.", "", 1))
			end
			return nil
		end
	end
	return nil
end

local function mime_of(path)
	local ok, line = pcall(function()
		local p = io.popen("file -bL --mime-type -- " .. ya.quote(path))
		if not p then
			return nil
		end
		local l = p:read("*l")
		p:close()
		return l
	end)
	if not ok or not line then
		return nil
	end
	return normalize_mime(line)
end

local function is_local(file)
	local ok, regular = pcall(function()
		return file.url.spec.is_regular
	end)
	return ok and regular == true
end

local function is_dir(file)
	local ok, dir = pcall(function()
		return file.cha.is_dir
	end)
	return ok and dir == true
end

local function selected_files()
	local files = {}
	for _, f in pairs(cx.active.selected) do
		files[#files + 1] = f
	end
	if #files == 0 then
		local h = cx.active.current.hovered
		if h then
			files[1] = h
		end
	end
	return files
end

-- Runs in yazi's sync context: this is the only place where cx is safe to
-- read.  We return plain data plus rule ids (ids are small userdata values;
-- returning them from ya.sync() works in yazi 26.9).
local collect = ya.sync(function()
	local files = selected_files()
	if #files == 0 then
		return { error = "No file selected" }
	end

	local out = {}
	local seen = {}
	for _, f in ipairs(files) do
		-- Directories and virtual files do not have a useful GIO "open with"
		-- list here; keep yazi's own openers and skip the system apps.
		if not is_local(f) or is_dir(f) then
			return { native = true }
		end

		local ok, path = pcall(function()
			return tostring(f.path)
		end)
		if not ok or not path or path == "" then
			local ok_url, urlpath = pcall(function()
				return tostring(f.url.path)
			end)
			if ok_url and urlpath and urlpath ~= "" then
				path = urlpath
			else
				return { error = "Cannot resolve the selected file path" }
			end
		end

		if not seen[path] then
			seen[path] = true

			-- cx.active.selected yields base File values (no fs::File:mime()).
			-- Normal file errors are caught here so a mixed selection falls
			-- back to the native picker instead of aborting the sync block.
			local mime
			local ok_mime, value = pcall(function()
				return f:mime()
			end)
			if ok_mime then
				mime = value
			end
			if not mime then
				mime = mime_of(path)
			end
			if not mime then
				return { error = "Cannot determine MIME type for " .. path }
			end

			-- rule matching needs a File userdata accepted by FileRef.  A base
			-- File constructed from url+cha works for both hovered fs.File
			-- values and selected base File values.
			local base
			local ok_base, converted = pcall(function()
				return File(f)
			end)
			if ok_base then
				base = converted
			else
				local ok_table, built = pcall(function()
					return File { url = f.url, cha = f.cha, extra = { link_to = nil } }
				end)
				if not ok_table then
					return { error = "Cannot convert selected file: " .. tostring(built) }
				end
				base = built
			end

			local rule
			for _, r in pairs(rt.open.rules:match({ file = base, mime = mime })) do
				rule = r
				break
			end
			if not rule then
				return { error = "No open rule matches " .. path }
			end

			local use = {}
			for _, name in ipairs(rule.use) do
				use[#use + 1] = name
			end

			out[#out + 1] = {
				path = path,
				mime = mime,
				rule_id = rule.id,
				use = use,
			}
		end
	end

	if #out == 0 then
		return { error = "No file selected" }
	end
	return { files = out }
end)

-- Runs in the sync context.  It removes the previous temporary openers,
-- registers the new ones, and appends them to the rules matched above.
local install = ya.sync(function(_, state, apps)
	-- 1. Remove opener groups from the previous invocation.
	dbg("install apps=" .. tostring(#(apps or {})) .. " files=" .. tostring(#state.files))
	local old = {}
	for name in pairs(rt.opener) do
		if name:match("^" .. PREFIX) then
			old[#old + 1] = name
		end
	end
	for _, name in ipairs(old) do
		rt.opener[name] = nil
	end
	dbg("removed old=" .. tostring(#old))

	-- 2. Strip stale temporary names from every open rule.  The picker has no
	--    completion callback, so this is the cleanup point for the last run.
	for _, rule in pairs(rt.open.rules:match()) do
		local use = strip_temp(rule.use)
		if #use ~= #rule.use and #use > 0 then
			rt.open.rules:update({ id = rule.id }, { use = use })
		end
	end

	-- 3. Register one opener per application.  GIO does the actual launch, so
	--    Terminal=true, flatpak apps and field codes are handled correctly.
	local helper = helper_path()
	local names = {}
	for _, app in ipairs(apps or {}) do
		local id = tostring(app.id or "")
		if id ~= "" then
			local key = PREFIX .. id:gsub("[^%w_%-%.]", "_")
			local desc = tostring(app.name or id):gsub("[%c]", " ")
			if app.default then
				desc = "* " .. desc
			end

			local run = string.format(
				"%s %s --launch %s -- %%s",
				ya.quote(PYTHON),
				ya.quote(helper),
				ya.quote(id)
			)
			rt.opener[key] = { {
				run = run,
				desc = desc,
				orphan = true,
			} }
			names[#names + 1] = key
		end
	end

	-- 4. Append the new app openers to each rule matched by a selected file.
	--    Files sharing a rule are updated only once.
	local done = {}
	for _, file in ipairs(state.files) do
		local key = tostring(file.rule_id)
		if not done[key] then
			done[key] = true
			local use = strip_temp(file.use)
			for _, name in ipairs(names) do
				use[#use + 1] = name
			end
			dbg("rule use=" .. table.concat(use, ","))
			if #use > 0 then
				rt.open.rules:update({ id = file.rule_id }, { use = use })
			end
		end
	end

	dbg("installed names=" .. tostring(#names))
	return #names
end)


local function notify_fallback(message, level)
	if message and message ~= "" then
		ya.notify {
			title = "Open with",
			content = message,
			timeout = 5,
			level = level or "warn",
		}
	end
	ya.emit("open", { interactive = true })
end

return {
	entry = function()
		if ya.target_os and ya.target_os() ~= "linux" then
			return notify_fallback("System application discovery is Linux-only", "warn")
		end
		if not rt.open or not rt.opener then
			return notify_fallback("Yazi 26.5.6+ is required for dynamic openers", "error")
		end

		local ok, state = pcall(collect)
		if not ok then
			return notify_fallback("Cannot read yazi state: " .. tostring(state), "error")
		end
		if not state or state.error then
			return notify_fallback(state and state.error or "No file selected", "warn")
		end
		if state.native then
			return ya.emit("open", { interactive = true })
		end

		dbg("collected files=" .. tostring(#state.files))
		local paths = {}
		for _, file in ipairs(state.files) do
			paths[#paths + 1] = file.path
		end

		local out, err = Command(PYTHON)
			:arg { helper_path(), "--list", "--" }
			:arg(paths)
			:output()

		if not out then
			return notify_fallback("Cannot run the GIO helper: " .. tostring(err), "error")
		end

		local data, decode_err = ya.json_decode(out.stdout)
		if not data then
			local stderr = tostring(out.stderr or "")
			local detail = stderr ~= "" and stderr or tostring(decode_err)
			return notify_fallback("Invalid GIO helper output: " .. detail, "error")
		end
		dbg("helper apps=" .. tostring(data.apps and #data.apps))
		if data.error then
			return notify_fallback(tostring(data.error), "warn")
		end

		local installed, install_err = pcall(install, state, data.apps or {})
		if not installed then
			return notify_fallback("Cannot install openers: " .. tostring(install_err), "error")
		end

		-- The native picker is built from YAZI.opener + YAZI.open, so the
		-- openers installed above show up here together with edit/reveal/etc.
		ya.emit("open", { interactive = true })
	end,
}
