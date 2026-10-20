---@meta
---@module 'ui/widget/menu'

---Menu widget for KOReader - Paginated list of items (used by the file
---browser, OPDS catalogs, history, ...)
---Only the members used by this plugin are described here.
---@class Menu : WidgetContainer
---@field title string Title shown in the title bar
---@field item_table table[] Items; each has at least a `text` field
---@field page number Current page (1-based)
---@field page_num number Number of pages
---@field perpage number Items per page
---@field items_per_page number|nil Items per page override
---@field page_info_text table Footer "Page x of y" button
---@field page_info_left_chev table Footer previous page button
---@field page_info_right_chev table Footer next page button
---@field close_callback function|nil Called when the menu is closed
local Menu = {}

---Create a Menu subclass
---@param self Menu
---@param o? table Subclass prototype
---@return Menu
function Menu:extend(o) end

---Create a Menu instance
---@param self Menu
---@param o? table Options
---@return Menu
function Menu:new(o) end

---Replace the items (and optionally the title), and go to the page holding `itemnumber`
---@param self Menu
---@param new_title string|nil
---@param new_item_table table[]|nil
---@param itemnumber? number
---@param itemmatch? table
---@param new_subtitle? string
function Menu:switchItemTable(new_title, new_item_table, itemnumber, itemmatch, new_subtitle) end

---Refresh the footer (page number and navigation buttons)
---@param self Menu
---@param select_number? number
function Menu:updatePageInfo(select_number) end

---@param self Menu
---@return boolean
function Menu:onNextPage() end

---@param self Menu
---@return boolean
function Menu:onPrevPage() end

---@param self Menu
---@return boolean
function Menu:onClose() end

return Menu
