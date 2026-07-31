local H = require("helpers")

-- Tests de integracion: invocan cmake y el compilador de verdad.
describe("cmake_builder / integracion con cmake", function()
  local cmake, root, restore_notify, notifications

  before_each(function()
    cmake = H.fresh_module()
    restore_notify, notifications = H.capture_notify()
    vim.fn.setqflist({}, "r")
  end)

  after_each(function()
    restore_notify()
  end)

  --- Corre ensure_built y espera el callback. Devuelve status, path.
  local function ensure(bin)
    local status, path
    cmake.ensure_built(bin,
      function(p) status, path = "ready", p end,
      function() status = "error" end)
    H.wait_for(function() return status ~= nil end, 90000)
    return status, path
  end

  it("sin directorio build/ => on_error y no lanza cmake", function()
    root = H.make_project()
    vim.cmd("cd " .. root)
    local status = ensure(root .. "/build/hello")
    assert.equals("error", status)
    assert.equals(0, vim.fn.isdirectory(root .. "/build"))
  end)

  it("build exitoso => on_ready y binario ejecutable", function()
    root = H.make_project()
    vim.cmd("cd " .. root)
    assert.equals(0, H.configure(root, "Debug"))

    local status, path = ensure(root .. "/build/hello")
    assert.equals("ready", status)
    assert.equals(root .. "/build/hello", path)
    assert.equals(1, vim.fn.executable(path))
    assert.equals("42", vim.trim(vim.system({ path }):wait().stdout))
  end)

  it("segunda llamada no recompila (mtime al dia)", function()
    root = H.make_project()
    vim.cmd("cd " .. root)
    assert.equals(0, H.configure(root, "Debug"))
    assert.equals("ready", ensure(root .. "/build/hello"))

    assert.is_false(cmake.needs_rebuild(root .. "/build/hello"))
  end)

  it("build/ sin CMAKE_BUILD_TYPE => reconfigura a Debug y el binario trae simbolos", function()
    root = H.make_project()
    vim.cmd("cd " .. root)
    assert.equals(0, H.configure(root, nil)) -- sin -DCMAKE_BUILD_TYPE

    local status, path = ensure(root .. "/build/hello")
    assert.equals("ready", status)

    local cache = table.concat(vim.fn.readfile(root .. "/build/CMakeCache.txt"), "\n")
    assert.is_truthy(cache:match("CMAKE_BUILD_TYPE:%a+=Debug"))

    local sections = vim.system({ "readelf", "-S", path }):wait().stdout
    assert.is_truthy(sections:match("%.debug_info"), "el binario no tiene informacion de debug")
  end)

  it("error de compilacion => on_error y quickfix con item de tipo E", function()
    root = H.make_project({ broken = true })
    vim.cmd("cd " .. root)
    assert.equals(0, H.configure(root, "Debug"))

    local status = ensure(root .. "/build/hello")
    assert.equals("error", status)

    local qf = vim.fn.getqflist()
    local errors = vim.tbl_filter(function(i) return i.type == "E" end, qf)
    assert.is_true(#errors > 0, "el quickfix no recogio ningun error de compilacion")

    local first = errors[1]
    assert.is_true(first.lnum > 0, "el item de quickfix no trae numero de linea")
    assert.is_true(first.bufnr > 0, "el item de quickfix no apunta a ningun fichero")
    assert.is_truthy(vim.api.nvim_buf_get_name(first.bufnr):match("main%.cpp$"))
  end)

  it("output_mode=float tambien puebla el quickfix al fallar", function()
    root = H.make_project({ broken = true })
    vim.cmd("cd " .. root)
    assert.equals(0, H.configure(root, "Debug"))
    cmake.setup({ output_mode = "float" })

    local status = ensure(root .. "/build/hello")
    assert.equals("error", status)

    local errors = vim.tbl_filter(function(i) return i.type == "E" end, vim.fn.getqflist())
    assert.is_true(#errors > 0, "en modo float los errores no llegaron al quickfix")
  end)

  -- BUG #4: reconfigure_debug pasa getcwd() como -S, no CMAKE_HOME_DIRECTORY del cache.
  it("reconfigure con cwd distinto del source dir del cache [BUG #4]", function()
    root = H.make_project()
    assert.equals(0, H.configure(root, nil)) -- sin build type => forzara reconfigure

    -- Caso real: el usuario hizo :cd a un subdirectorio y apunta build_dir hacia arriba.
    vim.fn.mkdir(root .. "/src/deep", "p")
    vim.cmd("cd " .. root .. "/src/deep")
    cmake.setup({ build_dir = "../../build" })

    local status = ensure(root .. "/build/hello")
    assert.equals("ready", status)
  end)
end)
