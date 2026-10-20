local _ = require('gettext')
local util = require('util')

-- **BookmarkFields** - Safe accessors for bookmark data returned by the API.
-- KOReader's JSON decoder maps JSON `null` to a sentinel function (which is
-- truthy), so optional fields must be type-checked rather than nil-checked.
local BookmarkFields = {}

local MAX_TEXT_TITLE_LENGTH = 80

---Return the value if it is a non-empty string, nil otherwise
---@param value any
---@return string|nil
function BookmarkFields.str(value)
    if type(value) == 'string' and value ~= '' then
        return value
    end
    return nil
end

local str = BookmarkFields.str

---Return the bookmark content table (empty table if missing)
---@param bookmark BookmarkResponse
---@return table
function BookmarkFields.getContent(bookmark)
    if type(bookmark.content) == 'table' then
        return bookmark.content
    end
    return {}
end

---Build a title from the first line of a text note
---@param text string
---@return string|nil
local function titleFromText(text)
    local first_line = text:match('^%s*([^\n]+)')
    if not first_line then
        return nil
    end
    -- Strip markdown heading markers
    first_line = first_line:gsub('^#+%s*', '')
    if #first_line > MAX_TEXT_TITLE_LENGTH then
        first_line = util.fixUtf8(first_line:sub(1, MAX_TEXT_TITLE_LENGTH), '') .. '…'
    end
    return str(first_line)
end

---Get the title to display for a bookmark, falling back to crawled metadata,
---file name, note text or URL
---@param bookmark BookmarkResponse
---@return string
function BookmarkFields.getTitle(bookmark)
    local content = BookmarkFields.getContent(bookmark)
    local title = str(bookmark.title)
        or str(content.title)
        or str(content.fileName)
        or (str(content.text) and titleFromText(content.text))
        or str(content.url)
        or str(content.sourceUrl)
        or _('Untitled')
    -- Titles may contain newlines or runs of whitespace
    title = title:gsub('%s+', ' ')
    return util.trim(title)
end

---Get the host name of a URL, without a leading "www."
---@param url string|nil
---@return string|nil
function BookmarkFields.getHost(url)
    if not str(url) then
        return nil
    end
    local host = url:match('^%a[%w+.-]*://([^/:?#]+)')
    if host then
        host = host:gsub('^www%.', '')
    end
    return host
end

return BookmarkFields
