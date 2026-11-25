local beta = require("beta")

local M = {}

function M.greet(name)
  return "alpha " .. name
end

function M.run()
  local who = "y"
  return beta.greet("x") .. M.greet(who)
end

return M
