local InputDialog = require('ui/widget/inputdialog')
local Menu = require('ui/widget/menu')
local NetworkMgr = require('ui/network/manager')
local UIManager = require('ui/uimanager')
local util = require('util')
local _ = require('gettext')
local T = require('ffi/util').template

local BookmarkBrowser = require('karakeep/features/browser/bookmark_browser')
local BookmarkFields = require('karakeep/shared/bookmark_fields')

local str = BookmarkFields.str

-- Dialogs shown by the HTTP client while browsing
local LOADING_DIALOGS = {
    loading = { text = _('Loading bookmarks…') },
    error = { text = _('Could not load bookmarks from Karakeep') },
}

local BrowseMenu = {}

-- Last search, to prefill the search dialog
local last_search = ''

---Build the query parameters for a page of bookmarks
---@param params table Extra parameters
---@param cursor string|nil
---@param page_size number
---@return table
local function pageQuery(params, cursor, page_size)
    local query = { limit = page_size, cursor = cursor, includeContent = false }
    for key, value in pairs(params) do
        query[key] = value
    end
    return query
end

---@param karakeep Karakeep
---@param title string
---@param params table Query parameters for GET /bookmarks
local function browseBookmarks(karakeep, title, params)
    BookmarkBrowser.open({
        ui = karakeep.ui,
        title = title,
        fetch_page = function(cursor, page_size)
            return karakeep.ui.karakeep_api:getBookmarks({
                query = pageQuery(params, cursor, page_size),
                dialogs = LOADING_DIALOGS,
            })
        end,
    })
end

---Get display names of lists, with parent list names as prefix (e.g. "Reading / Tech")
---@param lists ListResponse[]
---@return table<string, string> list id -> display name
local function getListPaths(lists)
    local by_id = {}
    for _, list in ipairs(lists) do
        by_id[list.id] = list
    end

    local paths = {}
    for _, list in ipairs(lists) do
        local names = { str(list.name) or '?' }
        local parent = by_id[str(list.parentId) or '']
        -- Depth limit guards against parent cycles
        local depth = 0
        while parent and depth < 10 do
            table.insert(names, 1, str(parent.name) or '?')
            parent = by_id[str(parent.parentId) or '']
            depth = depth + 1
        end
        paths[list.id] = table.concat(names, ' / ')
    end
    return paths
end

---Show the user's lists; selecting one browses its bookmarks
---@param karakeep Karakeep
local function showLists(karakeep)
    NetworkMgr:runWhenOnline(function()
        local result = karakeep.ui.karakeep_api:getLists({
            dialogs = {
                loading = { text = _('Loading lists…') },
                error = { text = _('Could not load lists from Karakeep') },
            },
        })
        if not result or type(result.lists) ~= 'table' then
            return
        end

        local paths = getListPaths(result.lists)
        local lists = {}
        for _, list in ipairs(result.lists) do
            table.insert(lists, { id = list.id, name = paths[list.id] })
        end
        table.sort(lists, function(a, b)
            return a.name:lower() < b.name:lower()
        end)

        local lists_menu
        local items = {}
        for _, list in ipairs(lists) do
            table.insert(items, {
                text = list.name,
                callback = function()
                    BookmarkBrowser.open({
                        ui = karakeep.ui,
                        title = list.name,
                        on_close_all = function()
                            UIManager:close(lists_menu)
                        end,
                        fetch_page = function(cursor, page_size)
                            return karakeep.ui.karakeep_api:getListBookmarks(list.id, {
                                query = pageQuery({}, cursor, page_size),
                                dialogs = LOADING_DIALOGS,
                            })
                        end,
                    })
                end,
            })
        end

        lists_menu = Menu:new({
            title = _('Lists'),
            item_table = items,
            is_borderless = true,
            is_popout = false,
            covers_fullscreen = true,
            title_bar_fm_style = true,
        })
        UIManager:show(lists_menu)
    end)
end

---Ask for search terms and browse the matching bookmarks
---@param karakeep Karakeep
local function showSearchDialog(karakeep)
    local dialog
    dialog = InputDialog:new({
        title = _('Search Karakeep'),
        input = last_search,
        input_hint = _('Search terms'),
        buttons = {
            {
                {
                    text = _('Cancel'),
                    id = 'close',
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _('Search'),
                    is_enter_default = true,
                    callback = function()
                        local search = util.trim(dialog:getInputText())
                        if search == '' then
                            return
                        end
                        last_search = search
                        UIManager:close(dialog)
                        BookmarkBrowser.open({
                            ui = karakeep.ui,
                            title = T(_('Search: %1'), search),
                            fetch_page = function(cursor, page_size)
                                return karakeep.ui.karakeep_api:searchBookmarks({
                                    query = pageQuery({ q = search }, cursor, page_size),
                                    dialogs = LOADING_DIALOGS,
                                })
                            end,
                        })
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---Get the "Browse bookmarks" menu item
---@param karakeep Karakeep
---@return table
function BrowseMenu.getBrowseMenuItem(karakeep)
    return {
        text = _('Browse bookmarks'),
        separator = true,
        sub_item_table = {
            {
                text = _('Unarchived'),
                callback = function()
                    browseBookmarks(karakeep, _('Unarchived'), { archived = false })
                end,
            },
            {
                text = _('Favourites'),
                callback = function()
                    browseBookmarks(karakeep, _('Favourites'), { favourited = true })
                end,
            },
            {
                text = _('Lists'),
                callback = function()
                    showLists(karakeep)
                end,
            },
            {
                text = _('Search'),
                callback = function()
                    showSearchDialog(karakeep)
                end,
            },
        },
    }
end

return BrowseMenu
