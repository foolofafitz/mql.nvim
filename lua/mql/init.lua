local M = {}

-- Sensible defaults (paths must be explicitly provided by the user)
local default_config = {
    metaeditor_path   = nil,    -- REQUIRED: Path to metaeditor64.exe
    mql5_include_path = nil,    -- REQUIRED: Path to your local MQL5 include directory
    bind_key          = "<F7>", -- Set to false if the user wants to map it themselves
}

M.config = {}

-- Expose the compile function publicly so users can trigger it via Lua API
function M.compile()
    local current_file = vim.api.nvim_buf_get_name(0)

    -- Only compile if we are actively sitting in an mq5 file
    if not current_file:match("%.mq5$") then
        vim.notify("[mql.nvim] Not a valid .mq5 file", vim.log.levels.WARN)
        return
    end

    vim.notify("[mql.nvim] Compiling with MetaEditor (Sandbox Mode)...", vim.log.levels.INFO)

    local src_dir = vim.fn.fnamemodify(current_file, ":h")
    local target_file_name = vim.fn.fnamemodify(current_file, ":t")
    local target_binary_name = vim.fn.fnamemodify(current_file, ":t:r") .. ".ex5"

    local metaeditor_path = vim.fn.expand(M.config.metaeditor_path)
    local mql5_global_include = vim.fn.expand(M.config.mql5_include_path)

    -- 1. Create a pristine, space-free temporary directory environment
    local build_dir = vim.fn.trim(vim.fn.system('mktemp -d /tmp/mql_build.XXXXXX'))
    if vim.v.shell_error ~= 0 or build_dir == "" then
        vim.notify("[mql.nvim] Failed to create temporary build directory.", vim.log.levels.ERROR)
        return
    end

    -- 2. Populate and prepare the sandbox environment synchronously
    vim.fn.system(string.format('cp -r "%s"/* "%s/"', src_dir, build_dir))

    -- Pure Lua Space-Stripper
    local sandbox_files = vim.fn.split(vim.fn.glob(build_dir .. "/*"), "\n")
    for _, file_path in ipairs(sandbox_files) do
        local old_name = vim.fn.fnamemodify(file_path, ":t")
        if old_name:match(" ") then
            local new_name = old_name:gsub(" ", "")
            os.rename(file_path, build_dir .. "/" .. new_name)
        end
    end

    -- Strip spaces inside quote-enclosed #include statements
    vim.fn.system(string.format(
        [[find "%s" -type f \( -name "*.mq5" -o -name "*.mqh" \) -exec sed -i ':a;s/\(#include "[^"]*\) \([^"]*"\)/\1\2/;ta' {} +]],
        build_dir))

    local sanitized_target_file = target_file_name:gsub(" ", "")
    local sanitized_binary_name = target_binary_name:gsub(" ", "")

    -- 3. Translate Linux / into Windows Z:\
    local win_build_dir         = "Z:\\" .. build_dir:sub(2):gsub("/", "\\")
    local win_include_dir       = "Z:\\" .. mql5_global_include:sub(2):gsub("/", "\\")

    local windows_target        = win_build_dir .. "\\" .. sanitized_target_file
    local windows_include       = win_include_dir
    local windows_log           = win_build_dir .. "\\build.log"
    local sandbox_log_file      = build_dir .. "/build.log"

    -- 4. Execute the compiler SYNCHRONOUSLY
    local compile_cmd           = string.format(
        'wine "%s" /compile:"%s" /inc:"%s" /log:"%s"',
        metaeditor_path, windows_target, windows_include, windows_log
    )
    vim.fn.system(compile_cmd)

    local compiled_bin_path = build_dir .. "/" .. sanitized_binary_name
    local final_bin_destination = src_dir .. "/" .. target_binary_name

    -- 5. Check if binary was built successfully
    if vim.fn.filereadable(compiled_bin_path) == 1 then
        vim.fn.system(string.format('mv "%s" "%s"', compiled_bin_path, final_bin_destination))
        vim.notify("[mql.nvim] MQL5 Compilation Successful!", vim.log.levels.INFO)
        vim.cmd [[ cclose ]]
    else
        vim.notify("[mql.nvim] Compilation Failed! Loading errors...", vim.log.levels.ERROR)

        if vim.fn.filereadable(sandbox_log_file) == 1 then
            local utf8_content = vim.fn.system({ "iconv", "-f", "utf-16le", "-t", "utf-8", sandbox_log_file })
            utf8_content = utf8_content:gsub("\r", "")
            local raw_lines = vim.split(utf8_content, "\n", { trimempty = true })

            local qf_items = {}

            local raw_project_files = vim.fn.split(vim.fn.glob(src_dir .. "/*"), "\n")
            local project_files = {}
            for _, f in ipairs(raw_project_files) do
                local base = vim.fn.fnamemodify(f, ":t")
                if not base:match("^%.") then
                    table.insert(project_files, f)
                end
            end

            for _, line in ipairs(raw_lines) do
                local filename, lnum, col, text = line:match("^([^(]+)%((%d+),(%d+)%)%s+:%s+(.*)$")

                if filename and lnum and col and text then
                    local clean_filename = vim.trim(filename)
                    local sandbox_file_name = clean_filename:match("[^\\]+$")
                    local real_file_destination = src_dir .. "/" .. sandbox_file_name

                    if vim.fn.filereadable(real_file_destination) ~= 1 then
                        for _, f in ipairs(project_files) do
                            local base = vim.fn.fnamemodify(f, ":t")
                            if base:gsub(" ", "") == sandbox_file_name then
                                real_file_destination = f
                                break
                            end
                        end
                    end

                    if vim.fn.filereadable(real_file_destination) ~= 1 then
                        real_file_destination = clean_filename:gsub("^%a+:", ""):gsub("\\", "/")
                    end

                    table.insert(qf_items, {
                        filename = real_file_destination,
                        lnum = tonumber(lnum),
                        col = tonumber(col),
                        text = vim.trim(text),
                        type = text:lower():match("error") and "E" or "W"
                    })
                end
            end

            if #qf_items > 0 then
                vim.fn.setqflist({}, ' ', { title = "MQL5 Compiler Errors", items = qf_items })
                vim.cmd("copen")
            else
                vim.notify("[mql.nvim] Failed to parse errors from log file.", vim.log.levels.WARN)
            end
        else
            vim.notify("[mql.nvim] Could not find compiler log file inside sandbox environment.", vim.log.levels.WARN)
        end
    end

    -- Cleanup
    vim.fn.system(string.format('rm -rf "%s"', build_dir))
end

function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", default_config, opts or {})

    -- Strict validation: both fields are required
    if not M.config.metaeditor_path or not M.config.mql5_include_path then
        vim.notify(
        "[mql.nvim] Error: Both 'metaeditor_path' and 'mql5_include_path' are REQUIRED in setup(). Plugin disabled.",
            vim.log.levels.ERROR)
        return
    end

    -- Setup filetype patterns safely during initialization
    vim.filetype.add({
        extension = {
            mq5 = "cpp",
            mqh = "cpp",
        },
    })
    vim.treesitter.language.register("cpp", "mql5")

    -- Set up keymap if requested
    if M.config.bind_key then
        vim.keymap.set("n", M.config.bind_key, function()
            M.compile()
        end, { desc = "Compile current MQL5 file via Wine" })
    end

    -- Quickfix window configuration helper
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "qf",
        callback = function(args)
            local buf_name = vim.api.nvim_buf_get_name(args.buf)
            if buf_name:match("neo%-tree") then return end

            vim.keymap.set("n", "l", "<CR>", {
                buffer = args.buf,
                remap = true,
                desc = "Open quickfix entry under cursor"
            })
        end,
    })
end

return M
