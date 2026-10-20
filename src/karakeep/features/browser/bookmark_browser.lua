local BD = require('ui/bidi')
local ButtonDialog = require('ui/widget/buttondialog')
local Menu = require('ui/widget/menu')
local NetworkMgr = require('ui/network/manager')
local Trapper = require('ui/trapper')
local UIManager = require('ui/uimanager')
local logger = require('logger')
local _ = require('gettext')
local T = require('ffi/util').template

local BookmarkFields = require('karakeep/shared/bookmark_fields')
local Notification = require('karakeep/shared/widgets/notification')

local str = BookmarkFields.str

-- Number of bookmarks fetched from Karakeep and shown per page
local PAGE_SIZE = 10

---@alias BookmarkPageFetcher fun(cursor: string|nil, page_size: number): PaginatedBookmarksResponse|nil, Error|nil

---@class BookmarkBrowserItem
---@field text string Bookmark title
---@field bookmark_id string

-- **BookmarkBrowser** - Full screen list of bookmark titles. Bookmarks are
-- fetched one page at a time: moving past the last loaded page fetches the
-- next one from Karakeep, moving back uses the pages already loaded.
---@class BookmarkBrowser : Menu
---@field ui UI
---@field fetch_page BookmarkPageFetcher
---@field next_cursor string|nil Cursor of the next page, nil when all pages are loaded
---@field on_close_all? fun() Called when the browser is closed to open a document
local BookmarkBrowser = Menu:extend({
    items_per_page = PAGE_SIZE,
    is_borderless = true,
    is_popout = false,
    covers_fullscreen = true,
    title_bar_fm_style = true,
})

---@param bookmarks BookmarkResponse[]
---@return BookmarkBrowserItem[]
local function toItems(bookmarks)
    local items = {}
    for _, bookmark in ipairs(bookmarks) do
        table.insert(items, {
            text = BookmarkFields.getTitle(bookmark),
            bookmark_id = bookmark.id,
        })
    end
    return items
end

---Fetch a page of bookmarks, showing a loading message
---@param fetch_page BookmarkPageFetcher
---@param cursor string|nil
---@return BookmarkBrowserItem[]|nil items, string|nil next_cursor
local function fetchItems(fetch_page, cursor)
    local result, err = fetch_page(cursor, PAGE_SIZE)
    if not result or type(result.bookmarks) ~= 'table' then
        logger.warn('[Karakeep:Browser] Failed to fetch bookmarks:', err and err.message)
        return nil
    end
    return toItems(result.bookmarks), str(result.nextCursor)
end

---Fetch the first page of bookmarks and show them in a new browser
---@param opts {ui: UI, title: string, fetch_page: BookmarkPageFetcher, on_close_all?: fun()}
function BookmarkBrowser.open(opts)
    NetworkMgr:runWhenOnline(function()
        local items, next_cursor = fetchItems(opts.fetch_page, nil)
        if not items then
            return
        end
        UIManager:show(BookmarkBrowser:new({
            ui = opts.ui,
            title = opts.title,
            fetch_page = opts.fetch_page,
            on_close_all = opts.on_close_all,
            item_table = items,
            next_cursor = next_cursor,
        }))
    end)
end

---@return boolean
function BookmarkBrowser:hasMorePages()
    return self.next_cursor ~= nil
end

---Show "Page 1 of 2+" and keep the next page button enabled while Karakeep has
---more bookmarks than the ones already loaded
function BookmarkBrowser:updatePageInfo(select_number)
    Menu.updatePageInfo(self, select_number)
    if #self.item_table > 0 and self:hasMorePages() then
        self.page_info_text:setText(T(_('Page %1 of %2+'), self.page, self.page_num))
        self.page_info_text:enable()
        self.page_info_right_chev:enableDisable(true)
    end
end

---Fetch the next page from Karakeep and show it
function BookmarkBrowser:loadNextPage()
    if self.loading then
        return
    end
    NetworkMgr:runWhenOnline(function()
        self.loading = true
        local items, next_cursor = fetchItems(self.fetch_page, self.next_cursor)
        self.loading = false
        if not items then
            return
        end

        local first_new_index = #self.item_table + 1
        for _, item in ipairs(items) do
            table.insert(self.item_table, item)
        end
        self.next_cursor = next_cursor
        -- Recompute page count, then go to the page holding the first new bookmark
        self:switchItemTable(nil, self.item_table, math.min(first_new_index, #self.item_table))
    end)
end

function BookmarkBrowser:onNextPage()
    if self.page >= self.page_num and self:hasMorePages() then
        self:loadNextPage()
        return true
    end
    return Menu.onNextPage(self)
end

---@param item BookmarkBrowserItem
function BookmarkBrowser:onMenuSelect(item)
    self:showBookmarkDialog(item)
    return true
end

---@param item BookmarkBrowserItem
function BookmarkBrowser:onMenuHold(item)
    self:showBookmarkDialog(item)
    return true
end

---Ask what to do with a bookmark
---@param item BookmarkBrowserItem
function BookmarkBrowser:showBookmarkDialog(item)
    local downloader = self.ui.karakeep_downloader
    local downloaded_path = downloader:getDownloadedPath(item.bookmark_id)

    local dialog
    local buttons
    if downloaded_path then
        buttons = {
            {
                {
                    text = _('Download again'),
                    callback = function()
                        UIManager:close(dialog)
                        self:downloadBookmark(item, false)
                    end,
                },
                {
                    text = _('Open'),
                    callback = function()
                        UIManager:close(dialog)
                        self:openDocument(downloaded_path)
                    end,
                },
            },
        }
    else
        buttons = {
            {
                {
                    text = _('Download'),
                    callback = function()
                        UIManager:close(dialog)
                        self:downloadBookmark(item, false)
                    end,
                },
                {
                    text = _('Download & open'),
                    callback = function()
                        UIManager:close(dialog)
                        self:downloadBookmark(item, true)
                    end,
                },
            },
        }
    end

    local title = item.text
    if downloaded_path then
        title = title .. '\n\n' .. _('Downloaded')
    end
    dialog = ButtonDialog:new({
        title = title,
        title_align = 'center',
        buttons = buttons,
    })
    UIManager:show(dialog)
end

---Download a bookmark, then open it or tell where it was saved
---@param item BookmarkBrowserItem
---@param open_after boolean
function BookmarkBrowser:downloadBookmark(item, open_after)
    local downloader = self.ui.karakeep_downloader
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local path, err = downloader:downloadBookmark(item.bookmark_id)
            Trapper:reset()
            if not path then
                if err then
                    Notification:error(err)
                end
                return
            end

            if open_after then
                -- Leave the Trapper coroutine before switching to the reader
                UIManager:nextTick(function()
                    self:openDocument(path)
                end)
                return
            end

            -- Show the new file if the file browser is in the download folder
            if self.ui.file_chooser then
                self.ui.file_chooser:refreshPath()
            end
            Notification:success(T(_('Saved to:\n%1'), BD.filepath(path)), { timeout = 3 })
        end)
    end)
end

---Close the browser (and its parent menus) and open a downloaded file
---@param path string
function BookmarkBrowser:openDocument(path)
    UIManager:close(self)
    if self.on_close_all then
        self.on_close_all()
    end
    local ui = self.ui
    if ui.document then
        ui:switchDocument(path)
    else
        ui:openFile(path)
    end
end

return BookmarkBrowser
