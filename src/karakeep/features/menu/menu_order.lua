local MenuSorter = require('ui/menusorter')
local util = require('util')

-- KOReader lists menu entries missing from its menu order last, so on most
-- screens the Karakeep entry ended up on the second page of the Tools tab.
local MENU_ID = 'karakeep'
local TOOLS_POSITION = 4

-- Default menu order of each menu, by the name KOReader uses for its custom order file
local DEFAULT_ORDER_MODULES = {
    filemanager = 'ui/elements/filemanager_menu_order',
    reader = 'ui/elements/reader_menu_order',
}

local MenuOrder = {}

local hooked = false

---Whether a menu order places Karakeep anywhere
---@param order table Menu id -> list of entry ids
---@return boolean
local function hasKarakeep(order)
    for _, entries in pairs(order) do
        if type(entries) == 'table' and util.arrayContains(entries, MENU_ID) then
            return true
        end
    end
    return false
end

---Add Karakeep to the Tools tab of a custom menu order, as KOReader reads it
---@param custom_order table
---@param default_module string
local function addToCustomOrder(custom_order, default_module)
    -- Placed by the user (or another plugin): keep it there
    if hasKarakeep(custom_order) then
        return
    end
    -- A custom order replaces whole menus of the default order. Without its own
    -- Tools list, give it a copy of the default one.
    if type(custom_order.tools) ~= 'table' then
        local ok, default_order = pcall(require, default_module)
        if not ok or type(default_order) ~= 'table' or type(default_order.tools) ~= 'table' then
            return
        end
        custom_order.tools = {}
        for _, id in ipairs(default_order.tools) do
            table.insert(custom_order.tools, id)
        end
        if util.arrayContains(custom_order.tools, MENU_ID) then
            return
        end
    end
    table.insert(custom_order.tools, math.min(TOOLS_POSITION, #custom_order.tools + 1), MENU_ID)
end

---Put the Karakeep entry 4th in the Tools tab of the file browser and the reader.
---Must run before the menus are first built.
---
---KOReader builds a menu from its default order, overridden by the custom
---order in settings/filemanager_menu_order.lua and reader_menu_order.lua
---(which other plugins, like BookOrbit, generate from the default order).
---Karakeep is added to the order as KOReader reads it, so neither the
---default order tables nor those files are changed.
function MenuOrder.addToToolsMenu()
    if hooked or type(MenuSorter.readMSSettings) ~= 'function' then
        return
    end
    hooked = true
    local readMSSettings = MenuSorter.readMSSettings
    MenuSorter.readMSSettings = function(sorter, config_prefix)
        local custom_order = readMSSettings(sorter, config_prefix)
        local default_module = DEFAULT_ORDER_MODULES[config_prefix]
        if default_module and type(custom_order) == 'table' then
            addToCustomOrder(custom_order, default_module)
        end
        return custom_order
    end
end

return MenuOrder
