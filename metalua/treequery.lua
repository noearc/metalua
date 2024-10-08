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
local walk = require("metalua.treequery.walk")

local M = {}
-- support for old-style modules
treequery = M

---multimap helper mmap: associate a key to a set of values
---@param mmap table the multimap
---@param node table the inner map
---@param x any the value
local function mmap_add(mmap, node, x)
   -- HACK:
   if node == nil or type(x) ~= "table" then
      return false
   end
   local set = mmap[node]
   if set then
      set[x] = true
   else
      mmap[node] = { [x] = true }
   end
end

---currently unused, I throw the whole set away
---@param mmap table the multimap
---@param node table the inner map
---@param x any the value
local function mmap_remove(mmap, node, x)
   local set = mmap[node]
   if not set then
      return false
   elseif not set[x] then
      return false
   elseif next(set) then
      set[x] = nil
   else
      mmap[node] = nil
   end
   return true
end

-- TreeQuery object.
local ACTIVE_SCOPE = setmetatable({}, { __mode = "k" })

-- treequery metatable
local Q = {}
Q.__index = Q

---@class treequery
---@field root table the AST to visit
---@field unsatisfied number the number of unsatisfied predicates
---@field predicates table[] the list of predicates
---@field until_up table the list of predicates to satisfy before going up
---@field from_up table the list of predicates to satisfy after going up
---@field up_f function | boolean the up callback
---@field down_f function | boolean the down callback
---@field filters function[] the list of filters

--- treequery constructor
--- the resultingg object will allow to filter ans operate on the AST
--- @param root AST the AST to visit
--- @return treequery visitor instance
function M.treequery(root)
   return setmetatable({
      root = root,
      unsatisfied = 0,
      predicates = {},
      until_up = {},
      from_up = {},
      up_f = false,
      down_f = false,
      filters = {},
   }, Q)
end

-- helper to share the implementations of positional filters
local function add_pos_filter(self, position, inverted, inclusive, f, ...)
   if type(f) == "string" then
      f = M.has_tag(f, ...)
   end
   if not inverted then
      self.unsatisfied = self.unsatisfied + 1
   end
   local x = {
      pred = f,
      position = position,
      satisfied = false,
      inverted = inverted or false,
      inclusive = inclusive or false,
   }
   table.insert(self.predicates, x)
   return self
end

function Q:if_unknown(f)
   self.unknown_handler = f or function()
      return nil
   end
   return self
end

-- TODO: offer an API for inclusive pos_filters

--- select nodes which are after one which satisfies predicate f
Q.after = function(self, f, ...)
   add_pos_filter(self, "after", false, false, f, ...)
end
--- select nodes which are not after one which satisfies predicate f
Q.not_after = function(self, f, ...)
   add_pos_filter(self, "after", true, false, f, ...)
end
--- select nodes which are under one which satisfies predicate f
Q.under = function(self, f, ...)
   add_pos_filter(self, "under", false, false, f, ...)
end
--- select nodes which are not under one which satisfies predicate f
Q.not_under = function(self, f, ...)
   add_pos_filter(self, "under", true, false, f, ...)
end

--- select nodes which satisfy predicate f
function Q:filter(f, ...)
   if type(f) == "string" then
      f = M.has_tag(f, ...)
   end
   table.insert(self.filters, f)
   return self
end

--- select nodes which satisfy predicate f
function Q:filter_not(f, ...)
   if type(f) == "string" then
      f = M.has_tag(f, ...)
   end
   table.insert(self.filters, function(...)
      return not f(...)
   end)
   return self
end

-- private helper: apply filters and execute up/down callbacks when applicable
function Q:execute()
   local cfg = {}
   -- TODO: optimize away not_under & not_after by pruning the tree
   function cfg.down(...)
      --printf ("[down]\t%s\t%s", self.unsatisfied, table.tostring((...)))
      ACTIVE_SCOPE[...] = cfg.scope
      local satisfied = self.unsatisfied == 0
      for _, x in ipairs(self.predicates) do
         if not x.satisfied and x.pred(...) then
            x.satisfied = true
            local node, parent = ...
            local inc = x.inverted and 1 or -1
            if x.position == "under" then
               -- satisfied from after we get down this node...
               self.unsatisfied = self.unsatisfied + inc
               -- ...until before we get up this node
               mmap_add(self.until_up, node, x)
            elseif x.position == "after" then
               -- satisfied from after we get up this node...
               mmap_add(self.from_up, node, x)
               -- ...until before we get up this node's parent
               mmap_add(self.until_up, parent, x)
            elseif x.position == "under_or_after" then
               -- satisfied from after we get down this node...
               self.satisfied = self.satisfied + inc
               -- ...until before we get up this node's parent...
               mmap_add(self.until_up, parent, x)
            else
               error("position not understood")
            end -- position
            if x.inclusive then
               satisfied = self.unsatisfied == 0
            end
         end -- predicate passed
      end -- for predicates

      if satisfied then
         for _, f in ipairs(self.filters) do
            if not f(...) then
               satisfied = false
               break
            end
         end
         if satisfied and self.down_f then
            self.down_f(...)
         end
      end
   end

   function cfg.up(...)
      --printf ("[up]\t%s", table.tostring((...)))

      -- Remove predicates which are due before we go up this node
      local preds = self.until_up[...]
      if preds then
         for x, _ in pairs(preds) do
            local inc = x.inverted and -1 or 1
            self.unsatisfied = self.unsatisfied + inc

            x.satisfied = false
         end
         self.until_up[...] = nil
      end

      -- Execute the up callback
      -- TODO: cache the filter passing result from the down callback
      -- TODO: skip if there's no callback
      local satisfied = self.unsatisfied == 0
      if satisfied then
         for _, f in ipairs(self.filters) do
            if not f(self, ...) then
               satisfied = false
               break
            end
         end
         if satisfied and self.up_f then
            self.up_f(...)
         end
      end

      -- Set predicate which are due after we go up this node
      preds = self.from_up[...]
      if preds then
         for p, _ in pairs(preds) do
            local inc = p.inverted and 1 or -1
            self.unsatisfied = self.unsatisfied + inc
         end
         self.from_up[...] = nil
      end
      ACTIVE_SCOPE[...] = nil
   end

   function cfg.binder(id_node, ...)
      --printf(" >>> Binder called on %s, %s", table.tostring(id_node),
      --      table.tostring{...}:sub(2,-2))
      cfg.down(id_node, ...)
      cfg.up(id_node, ...)
      --printf("down/up on binder done")
   end

   cfg.unknown = self.unknown_handler

   --function cfg.occurrence (binder, occ)
   --   if binder then OCC2BIND[occ] = binder[1] end
   --printf(" >>> %s is an occurrence of %s", occ[1], table.tostring(binder and binder[2]))
   --end

   --function cfg.binder(...) cfg.down(...); cfg.up(...) end
   return walk.guess(cfg, self.root)
end

--- Execute a function on each selected node
--  @down: function executed when we go down a node, i.e. before its children
--         have been examined.
--  @up: function executed when we go up a node, i.e. after its children
--       have been examined.
function Q:foreach(down, up)
   if not up and not down then
      error("iterator missing")
   end
   self.up_f = up
   self.down_f = down
   return self:execute()
end

--- Return the list of nodes selected by a given treequery.
function Q:list()
   local acc = {}
   self:foreach(function(x)
      -- HACK:
      if type(x) == "table" and x.tag then
         table.insert(acc, x)
      end
      -- return table.insert(acc, x)
   end)
   return acc
end

--- Return the first matching element
--  TODO:  dirty hack, to implement properly with a 'break' return.
--  Also, it won't behave correctly if a predicate causes an error,
--  or if coroutines are involved.
function Q:first()
   local result = {}
   local function f(...)
      result = { ... }
      error()
   end
   pcall(function()
      return self:foreach(f)
   end)
   return unpack(result)
end

--- Pretty printer for queries
function Q:__tostring()
   return "<treequery>"
end

---Predicates.

---Return a predicate which is true if the tested node's tag is among the
--- one listed as arguments
---@param ... string sequence of tag names
function M.has_tag(...)
   local args = { ... }
   if #args == 1 then
      local tag = ...
      return function(node)
         -- HACK:
         if type(node) ~= "table" then
            return false
         end
         return node.tag == tag
      end
      --return function(self, node) printf("node %s has_tag %s?", table.tostring(node), tag); return node.tag==tag end
   else
      local tags = {}
      for _, tag in ipairs(args) do
         tags[tag] = true
      end
      return function(node)
         local node_tag = node.tag
         return node_tag and tags[node_tag]
      end
   end
end

--- Predicate to test whether a node represents an expression.
M.is_expr = M.has_tag(
   "Nil",
   "Dots",
   "True",
   "False",
   "Number",
   "String",
   "Function",
   "Table",
   "Op",
   "Paren",
   "Call",
   "Invoke",
   "Id",
   "Index"
)

-- helper for is_stat
local STAT_TAGS = {
   Do = 1,
   Set = 1,
   While = 1,
   Repeat = 1,
   If = 1,
   Fornum = 1,
   Forin = 1,
   Local = 1,
   Localrec = 1,
   Return = 1,
   Break = 1,
}

--- Predicate to test whether a node represents a statement.
--  It is context-aware, i.e. it recognizes `Call and `Invoke nodes
--  used in a statement context as such.
function M.is_stat(node, parent)
   local tag = node.tag
   if not tag then
      return false
   elseif STAT_TAGS[tag] then
      return true
   elseif tag == "Call" or tag == "Invoke" then
      return parent.tag == nil
   else
      return false
   end
end

--- Predicate to test whether a node represents a statements block.
function M.is_block(node)
   return node.tag == nil
end

-- Variables and scopes.
local BINDER_PARENT_TAG = {
   Local = true,
   Localrec = true,
   Forin = true,
   Function = true,
}

--- Test whether a node is a binder. This is local predicate, although it
--  might need to inspect the parent node.
function M.is_binder(node, parent)
   --printf('is_binder(%s, %s)', table.tostring(node), table.tostring(parent))
   if node.tag ~= "Id" or not parent then
      return false
   end
   if parent.tag == "Fornum" then
      return parent[1] == node
   end
   if not BINDER_PARENT_TAG[parent.tag] then
      return false
   end
   for _, binder in ipairs(parent[1]) do
      if binder == node then
         return true
      end
   end
   return false
end

--- Retrieve the binder associated to an occurrence within root.
--  @param occurrence an Id node representing an occurrence in `root`.
--  @param root the tree in which `node` and its binder occur.
--  @return the binder node, and its ancestors up to root if found.
--  @return nil if node is global (or not an occurrence) in `root`.
function M.binder(occurrence, root)
   local cfg, id_name, result = {}, occurrence[1], {}
   function cfg.occurrence(id)
      if id == occurrence then
         result = cfg.scope:get(id_name)
      end
      -- TODO: break the walker
   end
   walk.guess(cfg, root)
   return unpack(result)
end

--- Predicate to filter occurrences of a given binder.
--  Warning: it relies on internal scope book-keeping,
--  and for this reason, it only works as query method argument.
--  It won't work outside of a query.
--  @param binder the binder whose occurrences must be kept by predicate
--  @return a predicate

-- function M.is_occurrence_of(binder)
--     return function(node, ...)
--         if node.tag ~= 'Id' then return nil end
--         if M.is_binder(node, ...) then return nil end
--         local scope = ACTIVE_SCOPE[node]
--         if not scope then return nil end
--         local result = scope :get (node[1]) or { }
--         if result[1] ~= binder then return nil end
--         return unpack(result)
--     end
-- end

function M.is_occurrence_of(binder)
   return function(node, ...)
      local b = M.get_binder(node)
      return b and b == binder
   end
end

function M.get_binder(occurrence, ...)
   if occurrence.tag ~= "Id" then
      return nil
   end
   if M.is_binder(occurrence, ...) then
      return nil
   end
   local scope = ACTIVE_SCOPE[occurrence]
   local binder_hierarchy = scope:get(occurrence[1])
   return unpack(binder_hierarchy or {})
end

--- Transform a predicate on a node into a predicate on this node's
--  parent. For instance if p tests whether a node has property P,
--  then parent(p) tests whether this node's parent has property P.
--  The ancestor level is precised with n, with 1 being the node itself,
--  2 its parent, 3 its grand-parent etc.
--  @param[optional] n the parent to examine, default=2
--  @param pred the predicate to transform
--  @return a predicate
function M.parent(n, pred, ...)
   if type(n) ~= "number" then
      n, pred = 2, n
   end
   if type(pred) == "string" then
      pred = M.has_tag(pred, ...)
   end
   return function(self, ...)
      return select(n, ...) and pred(self, select(n, ...))
   end
end

--- Transform a predicate on a node into a predicate on this node's
--  n-th child.
--  @param n the child's index number
--  @param pred the predicate to transform
--  @return a predicate
function M.child(n, pred)
   return function(node, ...)
      local child = node[n]
      return child and pred(child, node, ...)
   end
end

--- Predicate to test the position of a node in its parent.
--  The predicate succeeds if the node is the n-th child of its parent,
--  and a <= n <= b.
--  nth(a) is equivalent to nth(a, a).
--  Negative indices are admitted, and count from the last child,
--  as done for instance by string.sub().
--
--  TODO: This is wrong, this tests the table relationship rather than the
--  AST node relationship.
--  Must build a getindex helper, based on pattern matching, then build
--  the predicate around it.
--
--  @param a lower bound
--  @param a upper bound
--  @return a predicate
function M.is_nth(a, b)
   b = b or a
   return function(self, node, parent)
      if not parent then
         return false
      end
      local nchildren = #parent
      local a = a <= 0 and nchildren + a + 1 or a
      if a > nchildren then
         return false
      end
      local b = b <= 0 and nchildren + b + 1 or b > nchildren and nchildren or b
      for i = a, b do
         if parent[i] == node then
            return true
         end
      end
      return false
   end
end

-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------
--
-- Comments parsing.
--
-- -----------------------------------------------------------------------------
-- -----------------------------------------------------------------------------

local comment_extractor = function(which_side)
   return function(node)
      local x = node.lineinfo
      x = x and x[which_side]
      x = x and x.comments
      if not x then
         return nil
      end
      local lines = {}
      for _, record in ipairs(x) do
         table.insert(lines, record[1])
      end
      return table.concat(lines, "\n")
   end
end
M.comment_prefix = comment_extractor("first")
M.comment_suffix = comment_extractor("last")

--- Shortcut for the query constructor
function M:__call(...)
   return self.treequery(...)
end
setmetatable(M, M)

return M
