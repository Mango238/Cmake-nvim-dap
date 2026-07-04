-- lua/utils/cmake_builder.lua
--
-- Módulo reutilizable para integrar cmake builds asíncronos con nvim-dap.
-- Detecta si un binario está desactualizado usando mtime de archivos fuente,
-- ejecuta `cmake --build` si es necesario, muestra output en quickfix y
-- solo continúa la sesión DAP si el build fue exitoso.
--
-- Uso típico en una config de dap:
--
--   local cmake = require("utils.cmake_builder")
--   program = cmake.program_with_build("build/my_binary"),
--
-- O con detección automática del nombre del binario vía cmake:
--   program = cmake.program_with_build(),  -- pide la ruta al usuario si no puede inferirla

local bit = require("bit")

local M = {}

-- ─── Configuración por defecto ────────────────────────────────────────────────
-- Puedes sobreescribir estos valores llamando M.setup({ ... }) en tu init.
M.config = {
  -- Directorio de build relativo a cwd (sin trailing slash)
  build_dir = "build",

  -- Comando de build. Se ejecuta como:  cmake --build <build_dir> <extra_args>
  cmake_extra_args = {},

  -- Extensiones de archivos fuente que se consideran para la detección de mtime.
  -- Si alguno de estos tiene mtime > mtime del binario, se recompila.
  source_extensions = { "cpp", "cxx", "cc", "c", "h", "hpp", "hxx", "cmake", "CMakeLists.txt" },

  -- Directorios donde buscar fuentes (relativos a cwd). Puede incluir "src", "include", etc.
  -- Si está vacío, se usa el cwd completo (más lento pero más seguro).
  source_dirs = {},

  -- Número máximo de archivos a escanear para mtime (evita colgarse en proyectos grandes)
  max_source_files = 2000,

  -- Si es true, siempre compila sin verificar mtime (útil para proyectos con generated files)
  always_build = false,

  -- Dónde mostrar el output del build: "quickfix" | "float"
  output_mode = "quickfix",

  -- Si es true, abre el quickfix automáticamente cuando hay errores
  open_quickfix_on_error = true,
}

-- ─── setup() ──────────────────────────────────────────────────────────────────
-- Permite sobreescribir la configuración por defecto desde tu init.lua:
--   require("utils.cmake_builder").setup({ build_dir = "out", always_build = true })
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- ─── Utilidades internas ──────────────────────────────────────────────────────

--- Lista todos los ejecutables de un directorio y permite seleccionar uno.
--- Retorna el path absoluto del ejecutable o nil si el usuario cancela.
---
---@param dir string Directorio absoluto a inspeccionar.
---@return string|nil
function M.select_executable(dir)
    local uv = vim.uv

    local handle = uv.fs_scandir(dir)
    if not handle then
        vim.notify(
            "No se pudo abrir el directorio:\n" .. dir,
            vim.log.levels.ERROR
        )
        return nil
    end

    local executables = {}

    while true do
        local name, ftype = uv.fs_scandir_next(handle)
        if not name then
            break
        end

        if ftype == "file" then
            local fullpath = dir .. "/" .. name

            local stat = uv.fs_stat(fullpath)
            -- vim.notify(fullpath, vim.log.levels.INFO)
            if stat and stat.type == "file" then
                -- Comprueba permisos de ejecución (Unix)
                local mode = stat.mode or 0

                if bit.band(mode, 73) ~= 0 then
                    table.insert(executables, fullpath)
                end
            end
        end
    end

    table.sort(executables)

    if #executables == 0 then
        vim.notify(
            "No se encontraron ejecutables en:\n" .. dir,
            vim.log.levels.WARN
        )
        return nil
    end

    if #executables == 1 then
        return executables[1]
    end

    local co = coroutine.running()
    if co then
        -- vim.ui.select (snacks lo overridea con picker flotante)
        vim.ui.select(executables, {
            prompt = "Seleccionar ejecutable:",
            format_item = function(path)
                return vim.fn.fnamemodify(path, ":t")
            end,
        }, function(choice)
            coroutine.resume(co, choice)
        end)
        return coroutine.yield()
    end

    -- Fallback: vim.fn.inputlist (sin coroutine)
    local items = { "Seleccione un ejecutable:" }
    for i, path in ipairs(executables) do
        local name = vim.fn.fnamemodify(path, ":t")
        table.insert(items, i .. ". " .. name)
    end

    local choice = vim.fn.inputlist(items)

    if choice < 1 or choice > #executables then
        return nil
    end

    return executables[choice]
end


--- Devuelve el mtime de un archivo en segundos (unix timestamp), o 0 si no existe.
---@param path string
---@return number
local function get_mtime(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.mtime.sec or 0
end

--- Chequea recursivamente si algún archivo fuente tiene mtime > binary_mtime.
--- Devuelve true si hay que recompilar, false si el binario está al día.
---@param dirs string[]  directorios absolutos a escanear
---@param binary_mtime number
---@param extensions table<string, boolean>  set de extensiones válidas
---@param max_files number
---@return boolean needs_rebuild, number files_checked
local function sources_newer_than(dirs, binary_mtime, extensions, max_files)
  local count = 0

  local function scan(dir)
    if count >= max_files then return true end  -- corta rápido si ya sabe que hay rebuild

    local handle = vim.uv.fs_scandir(dir)
    if not handle then return false end

    while true do
      local name, ftype = vim.uv.fs_scandir_next(handle)
      if not name then break end

      local full = dir .. "/" .. name

      if ftype == "directory" then
        -- Ignora build/, .git/, node_modules/ y similares
        if name ~= "." and name ~= ".."
           and name ~= ".git"
           and name ~= "node_modules"
           and name ~= M.config.build_dir then
          if scan(full) then return true end
        end

      elseif ftype == "file" then
        count = count + 1
        -- Chequea extensión: "CMakeLists.txt" es nombre exacto, el resto por extensión
        local ext = name:match("%.([^%.]+)$") or ""
        local is_source = extensions[ext] or extensions[name]
        if is_source then
          local mtime = get_mtime(full)
          if mtime > binary_mtime then
            return true  -- encontró un fuente más nuevo, hay que recompilar
          end
        end

        if count >= max_files then return false end
      end
    end
    return false
  end

  for _, dir in ipairs(dirs) do
    if scan(dir) then
      return true, count
    end
  end

  return false, count
end

--- Abre un buffer flotante y devuelve una función `append(lines)` para escribir en él.
---@return fun(lines: string[]), number (bufnr)
local function open_float_output()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "cmake"

  local width = math.floor(vim.o.columns * 0.8)
  local height = math.floor(vim.o.lines * 0.5)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " CMake Build ",
    title_pos = "center",
  })

  vim.wo[winid].wrap = true
  vim.wo[winid].number = false

  local function append(lines)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
        -- Auto-scroll al final
        if vim.api.nvim_win_is_valid(winid) then
          local last = vim.api.nvim_buf_line_count(bufnr)
          vim.api.nvim_win_set_cursor(winid, { last, 0 })
        end
      end
    end)
  end

  return append, bufnr
end

--- Envía líneas al quickfix. Si replace=true reemplaza el contenido actual.
---@param lines string[]
---@param replace boolean
local function send_to_quickfix(lines, replace)
  local items = {}
  for _, line in ipairs(lines) do
    -- Intenta parsear errores tipo: /path/file.cpp:10:5: error: mensaje
    local file, lnum, col, text = line:match("^(.-)%:(%d+)%:(%d+)%: (.+)$")
    if file and lnum then
      table.insert(items, {
        filename = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = text,
        type = text:match("^error") and "E" or text:match("^warning") and "W" or "I",
      })
    else
      -- Línea sin posición: la pone como texto informativo
      table.insert(items, { text = line, type = "I" })
    end
  end

  vim.fn.setqflist({}, replace and "r" or "a", {
    title = "CMake Build",
    items = items,
  })
end

-- ─── Función principal de build ───────────────────────────────────────────────

--- Ejecuta `cmake --build <build_dir>` de forma asíncrona.
--- Llama a `on_done(success)` cuando termina.
---@param build_dir string  ruta absoluta al directorio de build
---@param on_done fun(success: boolean)
local function run_cmake_build(build_dir, on_done)
  local cfg = M.config
  local cmd = vim.list_extend(
    { "cmake", "--build", build_dir },
    cfg.cmake_extra_args
  )

  -- Limpia el quickfix antes de empezar
  vim.schedule(function()
    send_to_quickfix({ "── CMake Build ── " .. os.date("%H:%M:%S") .. " ──" }, true)
  end)

  -- Configura el output según el modo elegido
  local append_output
  local float_bufnr

  if cfg.output_mode == "float" then
    append_output, float_bufnr = open_float_output()
    vim.schedule(function()
      append_output({ "Building: " .. table.concat(cmd, " "), "" })
    end)
  else
    -- quickfix: solo se necesita la función de append
    append_output = function(lines)
      vim.schedule(function()
        send_to_quickfix(lines, false)
      end)
    end
    -- Abre el quickfix en modo preview mientras compila
    vim.schedule(function()
      vim.cmd("copen")
    end)
  end

  -- Notificación inicial
  vim.schedule(function()
    vim.notify("🔨 Building...", vim.log.levels.INFO, { title = "DAP / CMake" })
  end)

  local stdout_lines = {}

  -- vim.system está disponible desde Neovim 0.10.
  -- Para versiones anteriores (0.9.x) usa el bloque alternativo con vim.loop más abajo.
  vim.system(cmd, {
    cwd = vim.fn.getcwd(),

    -- stdout: recibe chunks, los parte por líneas y los envía al output
    stdout = function(err, data)
      if data then
        local lines = vim.split(data, "\n", { plain = true })
        -- Acumula para el chequeo final de errores
        for _, l in ipairs(lines) do
          if l ~= "" then table.insert(stdout_lines, l) end
        end
        append_output(lines)
      end
    end,

    -- stderr: los errores de compilación vienen por stderr en gcc/clang
    stderr = function(err, data)
      if data then
        local lines = vim.split(data, "\n", { plain = true })
        for _, l in ipairs(lines) do
          if l ~= "" then table.insert(stdout_lines, l) end
        end
        append_output(lines)
      end
    end,

  }, function(result)
    -- Callback al terminar el proceso (ya en hilo principal vía vim.schedule interno)
    local success = result.code == 0

    vim.schedule(function()
      if success then
        vim.notify("✅ Build exitoso", vim.log.levels.INFO, { title = "DAP / CMake" })
        if cfg.output_mode == "float" and float_bufnr then
          -- Cierra el float tras un momento si el build fue bien
          vim.defer_fn(function()
            if vim.api.nvim_buf_is_valid(float_bufnr) then
              vim.api.nvim_buf_delete(float_bufnr, { force = true })
            end
          end, 1500)
        else
          vim.cmd("cclose")
        end
      else
        vim.notify(
          "❌ Build fallido (code " .. result.code .. "). Ver quickfix.",
          vim.log.levels.ERROR,
          { title = "DAP / CMake" }
        )
        -- Asegura que el quickfix tenga todo el output y ábrelo
        if cfg.output_mode == "float" then
          -- En modo float los errores también van al quickfix para poder navegar
          send_to_quickfix(stdout_lines, true)
        end
        if cfg.open_quickfix_on_error then
          vim.cmd("copen")
        end
      end

      on_done(success)
    end)
  end)
end

-- ─── API pública ──────────────────────────────────────────────────────────────

--- Determina si el binario en `bin_path` necesita ser reconstruido.
--- Compara su mtime contra los archivos fuente en el proyecto.
---@param bin_path string  ruta absoluta al ejecutable
---@return boolean  true si hay que recompilar
function M.needs_rebuild(bin_path)
  if M.config.always_build then return true end

  local bin_mtime = get_mtime(bin_path)
  if bin_mtime == 0 then
    -- El binario no existe → siempre hay que compilar
    return true
  end

  -- Construye el set de extensiones para lookup O(1)
  local ext_set = {}
  for _, ext in ipairs(M.config.source_extensions) do
    ext_set[ext] = true
  end

  -- Directorios a escanear
  local cwd = vim.fn.getcwd()
  local dirs = {}
  if #M.config.source_dirs > 0 then
    for _, d in ipairs(M.config.source_dirs) do
      table.insert(dirs, cwd .. "/" .. d)
    end
  else
    table.insert(dirs, cwd)
  end

  local rebuild, checked = sources_newer_than(dirs, bin_mtime, ext_set, M.config.max_source_files)

  vim.notify(
    string.format("mtime check: %d archivos revisados, rebuild=%s", checked, tostring(rebuild)),
    vim.log.levels.DEBUG,
    { title = "cmake_builder" }
  )

  return rebuild
end

--- Función de alto nivel: verifica si hay que compilar, compila si es necesario
--- y llama a `on_ready(bin_path)` si el build fue exitoso, o `on_error()` si falló.
---
---@param bin_path string      ruta absoluta al ejecutable
---@param on_ready fun(path: string)   se llama con la ruta si todo está bien
---@param on_error fun()               se llama si el build falla (para abortar DAP)
function M.ensure_built(bin_path, on_ready, on_error)
  local cwd = vim.fn.getcwd()
  local build_dir = cwd .. "/" .. M.config.build_dir

  -- Verifica que el directorio build/ exista (no intenta hacer cmake configure)
  if vim.fn.isdirectory(build_dir) == 0 then
    vim.notify(
      "El directorio build/ no existe: " .. build_dir .. "\nEjecuta `cmake -S . -B build` primero.",
      vim.log.levels.ERROR,
      { title = "DAP / CMake" }
    )
    -- vim.schedule garantiza que on_error siempre llega DESPUÉS de coroutine.yield()
    -- en program_with_build, sin importar si la ruta es síncrona o asíncrona.
    vim.schedule(on_error)
    return
  end

  if not M.needs_rebuild(bin_path) then
    vim.notify("✓ Binario actualizado, no es necesario recompilar.", vim.log.levels.INFO, { title = "DAP / CMake" })
    -- Sin vim.schedule, on_ready se llamaría sincrónicamente ANTES de que
    -- program_with_build llegue a coroutine.yield(), así que el coroutine.resume
    -- dentro de on_ready dispararía en el vacío y el yield quedaría colgado.
    -- Diferir via vim.schedule rompe esa carrera: el yield siempre ocurre primero.
    vim.schedule(function() on_ready(bin_path) end)
    return
  end

  -- Hay que compilar: run_cmake_build ya es asíncrono, su callback llega
  -- vía vim.schedule interno (desde el hilo de vim.system), así que no
  -- hay riesgo de carrera aquí. Se deja igual.
  run_cmake_build(build_dir, function(success)
    if success then
      on_ready(bin_path)
    else
      on_error()
    end
  end)
end

--- Genera una función compatible con el campo `program` de nvim-dap.
--- La función pide la ruta al usuario (con el default dado), luego
--- invoca ensure_built y solo devuelve la ruta a dap si el build es exitoso.
---
--- Uso en dap_config.lua:
---   program = cmake.program_with_build("build/my_app"),
---   program = cmake.program_with_build(),    -- pide ruta completa al usuario
---
---@param default_binary string|nil  ruta relativa al binario dentro de build/ (ej: "build/app")
---@return fun(): string|nil   función que dap llama para resolver `program`
function M.program_with_build(default_binary)
  return function()
    local cwd = vim.fn.getcwd()

    -- Determina el path por defecto para el input
    local default_path
    if default_binary then
      -- Si el usuario pasó algo como "build/app" lo convierte a absoluto
      default_path = cwd .. "/" .. default_binary
    else
      default_path = cwd .. "/" .. M.config.build_dir .. "/"
    end

    -- Pide confirmación/modificación de la ruta al usuario
    local bin_path
    local co_input = coroutine.running()
    if co_input then
        -- vim.ui.input (snacks lo overridea con input flotante)
        vim.ui.input({
            prompt = "Ejecutable: ",
            default = default_path,
        }, function(input)
            bin_path = input
            coroutine.resume(co_input)
        end)
        coroutine.yield()
    else
        -- fallback: vim.fn.input sincrónico
        bin_path = vim.fn.input("Ejecutable: ", default_path, "file")
    end

    if not bin_path or bin_path == "" then
        vim.notify("Sesión DAP cancelada.", vim.log.levels.WARN)
        return nil
    end

    -- Si el usuario dejó una ruta a directorio (termina en "/" o es dir real),
    -- resolver el ejecutable ANTES de chequear mtime/build.
    local stat = vim.uv.fs_stat(bin_path)
    if stat and stat.type == "directory" then
        bin_path = M.select_executable(bin_path)
        if not bin_path then
            vim.notify("Sesión DAP cancelada (sin ejecutable seleccionado).", vim.log.levels.WARN)
            return nil
        end
    end
    -- nvim-dap espera un valor sincrónico de `program`, pero nosotros necesitamos
    -- hacer trabajo asíncrono. La solución es usar dap.run() manualmente en lugar
    -- de devolver desde aquí. Sin embargo, dap 0.6+ permite coroutines en `program`.
    -- Usamos la variante con coroutine para compatibilidad.
    --
    -- Si tu versión de nvim-dap NO soporta coroutines en `program`, usa en su lugar
    -- M.program_with_build_sync() que bloquea brevemente con vim.wait().

    -- Estrategia con coroutine (nvim-dap >= commit fd6aa38, ~2023):
    local co = coroutine.running()
    if co then
      -- Estamos dentro de un coroutine de dap: podemos hacer yield/resume
      local result_path = nil
      local build_ok = false

      M.ensure_built(bin_path, function(path)
          coroutine.resume(co, path)  -- path YA es el binario, no hace falta select_executable
      end, function()
          coroutine.resume(co, nil)
      end)

      -- Suspende este coroutine hasta que ensure_built termine
      return coroutine.yield()
    else
      -- Fallback: no hay coroutine (llamada directa). Usa vim.wait() para
      -- esperar el resultado asíncrono sin bloquear el event loop completamente.
      -- Esto puede causar un brief freeze; considera migrar a dap con coroutine support.
      local done = false
      local final_path = nil

      M.ensure_built(bin_path, function(path)
        final_path = path
        done = true
      end, function()
        done = true  -- final_path queda nil → dap recibe nil → no lanza
      end)

      -- Espera hasta 60 segundos (builds grandes)
      vim.wait(60000, function() return done end, 100)

      return final_path
    end
  end
end

--- Variante de program_with_build que siempre usa vim.wait() (sin coroutine).
--- Más simple pero puede freezar el editor unos milisegundos al finalizar el build.
--- Útil como fallback si tienes una versión antigua de nvim-dap.
---@param default_binary string|nil
---@return fun(): string|nil
function M.program_with_build_sync(default_binary)
  return function()
    local cwd = vim.fn.getcwd()
    local default_path = default_binary
      and (cwd .. "/" .. default_binary)
      or (cwd .. "/" .. M.config.build_dir .. "/")

    local bin_path
    local co_sync = coroutine.running()
    if co_sync then
        vim.ui.input({
            prompt = "Ejecutable: ",
            default = default_path,
        }, function(input)
            bin_path = input
            coroutine.resume(co_sync)
        end)
        coroutine.yield()
    else
        bin_path = vim.fn.input("Ejecutable: ", default_path, "file")
    end

    if not bin_path or bin_path == "" then return nil end

    local done = false
    local final_path = nil

    M.ensure_built(bin_path, function(path)
      final_path = path
      done = true
    end, function()
      done = true
    end)

    vim.wait(60000, function() return done end, 100)
    return final_path
  end
end

return M
