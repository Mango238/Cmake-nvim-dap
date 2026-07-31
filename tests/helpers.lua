local H = {}

local function write(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- Crea un proyecto CMake minimo en un tmpdir y devuelve su ruta absoluta.
---@param opts table|nil  { broken = bool, extra_sources = number }
---@return string root
function H.make_project(opts)
  opts = opts or {}
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/src", "p")

  write(root .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.16)
project(hello CXX)
file(GLOB SOURCES src/*.cpp)
add_executable(hello ${SOURCES})
]])

  if opts.broken then
    -- No compila: tipo inexistente en la linea 3, columna conocida.
    write(root .. "/src/main.cpp", [[
#include <iostream>
int main() {
  no_such_type x = 1;
  std::cout << x;
  return 0;
}
]])
  else
    write(root .. "/src/main.cpp", [[
#include <iostream>
int main() {
  int x = 41;
  std::cout << x + 1 << std::endl;
  return 0;
}
]])
  end

  -- Fuentes de relleno para los tests de escaneo/tope de archivos.
  for i = 1, (opts.extra_sources or 0) do
    vim.fn.mkdir(string.format("%s/src/sub%d", root, i), "p")
    write(string.format("%s/src/sub%d/f%d.cpp", root, i, i), "// filler\n")
  end

  return root
end

--- Configura (cmake -S -B) el proyecto de forma sincrona. Devuelve exit code.
---@param root string
---@param build_type string|nil  nil => sin -DCMAKE_BUILD_TYPE
function H.configure(root, build_type)
  local cmd = { "cmake", "-S", root, "-B", root .. "/build" }
  if build_type then
    table.insert(cmd, "-DCMAKE_BUILD_TYPE=" .. build_type)
  end
  return vim.system(cmd, { cwd = root }):wait().code
end

--- Ejecuta `fn` dentro de un coroutine (como hace nvim-dap con `program`) y
--- espera a que muera. Devuelve done, value.
--- Si `fn` se cuelga en un yield sin resume, done = false en vez de colgar el runner.
---@param fn fun(): any
---@param timeout_ms number|nil
---@return boolean done, any value
function H.run_in_coroutine(fn, timeout_ms)
  local value, errored
  local co = coroutine.create(function()
    value = fn()
  end)

  local ok, err = coroutine.resume(co)
  if not ok then errored = err end

  vim.wait(timeout_ms or 5000, function()
    return coroutine.status(co) == "dead"
  end, 20)

  return coroutine.status(co) == "dead", value, errored
end

--- Sustituye vim.ui.input / vim.ui.select. Devuelve una funcion restore().
---@param behaviour "sync"|"async"  sync = stock Neovim, async = snacks/dressing
---@param answers table  { input = string|nil, select_index = number|nil }
function H.stub_ui(behaviour, answers)
  answers = answers or {}
  local orig_input, orig_select = vim.ui.input, vim.ui.select

  local function deliver(cb, val)
    if behaviour == "async" then
      vim.schedule(function() cb(val) end)
    else
      cb(val) -- stock: callback sincrono, ANTES de que el llamador haga yield
    end
  end

  vim.ui.input = function(_, on_confirm)
    deliver(on_confirm, answers.input)
  end

  vim.ui.select = function(items, _, on_choice)
    deliver(on_choice, items[answers.select_index or 1])
  end

  return function()
    vim.ui.input, vim.ui.select = orig_input, orig_select
  end
end

--- Recarga el modulo para resetear M.config entre tests.
---@return table
function H.fresh_module()
  package.loaded["cmake_builder"] = nil
  return require("cmake_builder")
end

--- Espera a que `pred` sea true. Devuelve true si se cumplio.
function H.wait_for(pred, timeout_ms)
  return vim.wait(timeout_ms or 5000, pred, 20)
end

--- Silencia vim.notify durante el test y devuelve restore() + la lista de mensajes.
function H.capture_notify()
  local orig = vim.notify
  local msgs = {}
  vim.notify = function(msg, level, _)
    table.insert(msgs, { msg = msg, level = level })
  end
  return function() vim.notify = orig end, msgs
end

return H
