local H = require("helpers")

-- Tests unitarios: no invocan cmake, solo logica del modulo.
describe("cmake_builder / unidad", function()
  local cmake, root, restore_notify, restore_ui

  before_each(function()
    cmake = H.fresh_module()
    root = H.make_project()
    vim.cmd("cd " .. root)
    restore_notify = H.capture_notify()
  end)

  after_each(function()
    if restore_ui then restore_ui(); restore_ui = nil end
    restore_notify()
  end)

  -- ── needs_rebuild ──────────────────────────────────────────────────────────
  describe("needs_rebuild", function()
    local function touch(path, when)
      vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
      if vim.fn.filereadable(path) == 0 then
        io.open(path, "w"):close()
      end
      vim.uv.fs_utime(path, when, when)
    end

    it("binario inexistente => rebuild", function()
      assert.is_true(cmake.needs_rebuild(root .. "/build/hello"))
    end)

    it("binario mas nuevo que las fuentes => no rebuild", function()
      local now = os.time()
      touch(root .. "/src/main.cpp", now - 100)
      touch(root .. "/CMakeLists.txt", now - 100)
      touch(root .. "/build/hello", now)
      assert.is_false(cmake.needs_rebuild(root .. "/build/hello"))
    end)

    it("fuente tocada despues del binario => rebuild", function()
      local now = os.time()
      touch(root .. "/build/hello", now - 100)
      touch(root .. "/src/main.cpp", now)
      assert.is_true(cmake.needs_rebuild(root .. "/build/hello"))
    end)

    it("always_build ignora el mtime", function()
      local now = os.time()
      touch(root .. "/src/main.cpp", now - 100)
      touch(root .. "/build/hello", now)
      cmake.setup({ always_build = true })
      assert.is_true(cmake.needs_rebuild(root .. "/build/hello"))
    end)

    it("no escanea dentro de build_dir", function()
      local now = os.time()
      touch(root .. "/src/main.cpp", now - 100)
      touch(root .. "/CMakeLists.txt", now - 100)
      touch(root .. "/build/hello", now - 50)
      -- Un .cpp generado dentro de build/ es mas nuevo, pero no debe contar.
      touch(root .. "/build/generated.cpp", now)
      assert.is_false(cmake.needs_rebuild(root .. "/build/hello"))
    end)

    -- BUG #3: el tope max_source_files es incoherente. :173 devuelve true al entrar a
    -- un subdirectorio con el cupo agotado, pero :205 devuelve false al agotarlo dentro
    -- de un directorio (y el escaneo continua). El resultado depende del orden de
    -- scandir: con 11 fuentes limpias, max 3..6 inventan un rebuild; 1, 2 y 2000 no.
    it("max_source_files no debe inventar un rebuild [BUG #3]", function()
      local now = os.time()
      root = H.make_project({ extra_sources = 10 })
      vim.cmd("cd " .. root)
      -- TODAS las fuentes son mas viejas que el binario: la respuesta correcta es false,
      -- se corte el escaneo por el tope o no. Como mucho el tope puede dar un falso
      -- negativo (no detectar un cambio), nunca un rebuild inventado.
      local function stamp(dir)
        for _, name in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
          if vim.fn.isdirectory(name) == 1 then stamp(name)
          else vim.uv.fs_utime(name, now - 100, now - 100) end
        end
      end
      stamp(root)
      touch(root .. "/build/hello", now)

      for _, max in ipairs({ 1, 2, 3, 4, 5, 6, 2000 }) do
        cmake = H.fresh_module()
        cmake.setup({ max_source_files = max })
        assert.is_false(cmake.needs_rebuild(root .. "/build/hello"),
          "rebuild espurio con max_source_files=" .. max)
      end
    end)
  end)

  -- ── setup() ────────────────────────────────────────────────────────────────
  describe("setup", function()
    -- Regresion: en Neovim < 0.10 tbl_deep_extend fusionaba listas por indice; desde
    -- 0.10 las reemplaza. Este test fija el comportamiento correcto.
    it("source_extensions pasado por el usuario reemplaza, no fusiona", function()
      cmake.setup({ source_extensions = { "cpp" } })
      assert.same({ "cpp" }, cmake.config.source_extensions)
    end)

    it("escalares si se sobreescriben bien", function()
      cmake.setup({ build_dir = "out", always_build = true })
      assert.equals("out", cmake.config.build_dir)
      assert.is_true(cmake.config.always_build)
    end)
  end)

  -- ── select_executable ──────────────────────────────────────────────────────
  describe("select_executable", function()
    local function make_exec(path)
      io.open(path, "w"):close()
      vim.uv.fs_chmod(path, 493) -- 0755
    end

    it("directorio sin ejecutables => nil", function()
      vim.fn.mkdir(root .. "/empty", "p")
      assert.is_nil(cmake.select_executable(root .. "/empty"))
    end)

    it("un solo ejecutable => lo devuelve sin preguntar", function()
      vim.fn.mkdir(root .. "/one", "p")
      make_exec(root .. "/one/app")
      assert.equals(root .. "/one/app", cmake.select_executable(root .. "/one"))
    end)

    it("varios ejecutables con UI asincrona (snacks) => devuelve la eleccion", function()
      vim.fn.mkdir(root .. "/many", "p")
      make_exec(root .. "/many/aaa")
      make_exec(root .. "/many/bbb")
      restore_ui = H.stub_ui("async", { select_index = 2 })

      local done, value = H.run_in_coroutine(function()
        return cmake.select_executable(root .. "/many")
      end, 2000)

      assert.is_true(done)
      assert.equals(root .. "/many/bbb", value)
    end)

    -- Regresion bug #2: con vim.ui.select de stock (sincrono) el resume llegaba antes
    -- del yield y la coroutine quedaba colgada. await_ui lo absorbe.
    it("varios ejecutables con UI sincrona (Neovim stock) no se cuelga", function()
      vim.fn.mkdir(root .. "/many", "p")
      make_exec(root .. "/many/aaa")
      make_exec(root .. "/many/bbb")
      restore_ui = H.stub_ui("sync", { select_index = 2 })

      local done, value = H.run_in_coroutine(function()
        return cmake.select_executable(root .. "/many")
      end, 2000)

      assert.is_true(done, "la coroutine quedo colgada en coroutine.yield()")
      assert.equals(root .. "/many/bbb", value)
    end)
  end)

  -- ── program_with_build ─────────────────────────────────────────────────────
  describe("program_with_build", function()
    it("con UI asincrona (snacks) resuelve la ruta", function()
      assert.equals(0, H.configure(root, "Debug"))
      restore_ui = H.stub_ui("async", { input = root .. "/build/hello" })

      local done, value = H.run_in_coroutine(cmake.program_with_build("build/hello"), 60000)

      assert.is_true(done)
      assert.equals(root .. "/build/hello", value)
    end)

    -- Regresion bug #1: vim.ui.input de stock llama al callback de forma sincrona,
    -- el coroutine.resume se perdia y el yield siguiente colgaba la sesion DAP.
    it("con UI sincrona (Neovim stock) no se cuelga", function()
      assert.equals(0, H.configure(root, "Debug"))
      restore_ui = H.stub_ui("sync", { input = root .. "/build/hello" })

      local done, value = H.run_in_coroutine(cmake.program_with_build("build/hello"), 60000)

      assert.is_true(done, "la sesion DAP quedaria colgada para siempre en coroutine.yield()")
      assert.equals(root .. "/build/hello", value)
    end)

    it("input vacio cancela la sesion (nil)", function()
      restore_ui = H.stub_ui("async", { input = "" })
      local done, value = H.run_in_coroutine(cmake.program_with_build("build/hello"), 5000)
      assert.is_true(done)
      assert.is_nil(value)
    end)

    -- vim.ui.input entrega nil cuando el usuario aborta (no "" ). Con UI sincrona
    -- ese camino tambien pasaba por el yield colgado.
    it("cancelacion con UI sincrona devuelve nil sin colgarse", function()
      restore_ui = H.stub_ui("sync", { input = nil })
      local done, value = H.run_in_coroutine(cmake.program_with_build("build/hello"), 5000)
      assert.is_true(done)
      assert.is_nil(value)
    end)
  end)

  describe("program_with_build_sync", function()
    -- Comparte el prompt con program_with_build, asi que compartia el bug #1.
    it("con UI sincrona (Neovim stock) resuelve la ruta", function()
      assert.equals(0, H.configure(root, "Debug"))
      restore_ui = H.stub_ui("sync", { input = root .. "/build/hello" })

      local done, value = H.run_in_coroutine(cmake.program_with_build_sync("build/hello"), 60000)

      assert.is_true(done)
      assert.equals(root .. "/build/hello", value)
    end)
  end)
end)
