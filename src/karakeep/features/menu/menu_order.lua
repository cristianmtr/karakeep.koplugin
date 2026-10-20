local logger = require('logger')
local util = require('util')

-- KOReader lists menu entries missing from its menu order last, so on most
-- screens the Karakeep entry ended up on the second page of the Tools tab.
local MENU_ID = 'karakeep'
local TOOLS_POSITION = 4

local ORDER_MODULES = {
    'ui/elements/filemanager_menu_order',
    'ui/elements/reader_menu_order',
}

local MenuOrder = {}

---Put the Karakeep entry 4th in the Tools tab of the file browser and the reader.
---Must run before the menus are first built. A custom menu order set up by
---the user (settings/*_menu_order.lua) still takes precedence.
function MenuOrder.addToToolsMenu()
    for _, module_name in ipairs(ORDER_MODULES) do
        local ok, order = pcall(require, module_name)
        if ok and type(order) == 'table' and type(order.tools) == 'table' then
            -- Plugins are initialized for every file browser and reader instance
            if not util.arrayContains(order.tools, MENU_ID) then
                table.insert(order.tools, math.min(TOOLS_POSITION, #order.tools + 1), MENU_ID)
            end
        else
            logger.warn('[Karakeep:Menu] Menu order not found:', module_name)
        end
    end
end

return MenuOrder
