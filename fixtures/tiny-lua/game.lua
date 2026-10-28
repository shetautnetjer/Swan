-- A tiny game loop: the cases for Lua search and live errors.
local Player = {}
Player.__index = Player

function Player.new(name)
    return setmetatable({ name = name, health = 100 }, Player)
end

function Player:hit(damage)
    self.health = self.health - damage
    print(self.name .. " has " .. self.health)
end

local hero = Player.new("hero")
hero:hit(10)
return Player
