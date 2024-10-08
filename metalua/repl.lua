-------------------------------------------------------------------------------
-- Copyright (c) 2006-2013 Fabien Fleutot and others.
--
-- All rights reserved.
--
-- This program and the accompanying materials are made available
-- under the terms of the Eclipse Public License v1.0 which
-- accompanies this distribution, and is available at
-- http://www.eclipse.org/legal/epl-v10.html
--
-- This program and the accompanying materials are also made available
-- under the terms of the MIT public license which accompanies this
-- distribution, and is available at http://www.lua.org/license.html
--
-- Contributors:
--     Fabien Fleutot - API and implementation
--
-------------------------------------------------------------------------------

-- Keep these global:
PRINT_AST = true
LINE_WIDTH = 60
PROMPT = "M> "
PROMPT2 = ">> "

local pp = require("metalua.pprint")
local M = {}

local mlc = require("metalua.compiler").new()

local readline

do -- set readline() to a line reader, either editline otr a default
   local status, _ = pcall(require, "editline")
   if status then
      local rl_handle = editline.init("metalua")
      readline = function(p)
         rl_handle:read(p)
      end
   else
      local status, rl = pcall(require, "readline")
      if status then
         rl.set_options({ histfile = "~/.metalua_history", keeplines = 100, completion = false })
         readline = rl.readline
      else -- neither editline nor readline available
         function readline(p)
            io.write(p)
            io.flush()
            return io.read("*l")
         end
      end
   end
end

local function reached_eof(lx, msg)
   return lx:peek().tag == "Eof" or msg:find("token `Eof")
end

function M.run()
   pp.printf("Metalua, interactive REPLoop.\n" .. "(c) 2006-2013 <metalua@gmail.com>")
   local lines = {}
   while true do
      local src, lx, ast, f, results, success
      repeat
         local line = readline(next(lines) and PROMPT2 or PROMPT)
         if not line then
            print()
            os.exit(0)
         end -- line==nil iff eof on stdin
         if not next(lines) then
            line = line:gsub("^%s*=", "return ")
         end
         table.insert(lines, line)
         src = table.concat(lines, "\n")
      until #line > 0
      lx = mlc:src_to_lexstream(src)
      success, ast = pcall(mlc.lexstream_to_ast, mlc, lx)
      -- ast = { tag = "Return", { tag = "Function", lineinfo = ast.lineinfo, { { tag = "Dots" } }, ast } }
      -- ast = { ast }
      if success then
         success, f = pcall(mlc.ast_to_function, mlc, ast, "=stdin")
         if success then
            results = { xpcall(f, debug.traceback) }
            -- results = { f() }
            success = table.remove(results, 1)
            if success then
               -- Success!
               for _, x in ipairs(results) do
                  pp.print(x, { line_max = LINE_WIDTH, metalua_tag = true })
               end
               lines = {}
            else
               print("Evaluation error:")
               print(results[1])
               lines = {}
            end
         else
            print("Can't compile into bytecode:")
            print(f)
            lines = {}
         end
      else
         -- If lx has been read entirely, try to read
         --  another line before failing.
         if not reached_eof(lx, ast) then
            print("Can't compile source into AST:")
            print(ast)
            lines = {}
         end
      end
   end
end

return M
