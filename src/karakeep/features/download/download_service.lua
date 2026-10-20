local EventListener = require('ui/widget/eventlistener')
local LuaSettings = require('luasettings')
local Trapper = require('ui/trapper')
local filemanagerutil = require('apps/filemanager/filemanagerutil')
local http = require('socket/http')
local lfs = require('libs/libkoreader-lfs')
local logger = require('logger')
local socket = require('socket')
local socketutil = require('socketutil')
local util = require('util')
local _ = require('gettext')
local T = require('ffi/util').template

local BookmarkFields = require('karakeep/shared/bookmark_fields')
local EpubBuilder = require('karakeep/features/download/epub_builder')
local Error = require('karakeep/shared/error')
local Files = require('karakeep/shared/files')

local str = BookmarkFields.str

-- Max bytes of a title used in file names
local FILENAME_TITLE_LIMIT = 100

---@class DownloadEntry
---@field path string Local file path
---@field title string Bookmark title at download time
---@field downloaded_at number Unix timestamp

-- **DownloadService** - Downloads Karakeep bookmarks as local files (EPUB for
-- articles and notes, the original file for PDFs and images) and remembers
-- which bookmarks were downloaded.
---@class DownloadService : EventListener
---@field ui UI
---@field settings Settings
---@field data_dir string
---@field index LuaSettings Bookmark id -> DownloadEntry
local DownloadService = EventListener:extend({})

function DownloadService:init()
    self.index = LuaSettings:open(self.data_dir .. 'downloads.lua')
end

---Default download folder: a "Karakeep" folder inside the home folder
---@return string
function DownloadService.getDefaultDownloadDir()
    -- selene: allow(undefined_variable)
    local home_dir = G_reader_settings:readSetting('home_dir') or filemanagerutil.getDefaultDir()
    return Files.rtrimSlashes(home_dir) .. '/Karakeep'
end

---@return string
function DownloadService:getDownloadDir()
    local download_dir = self.settings.download_dir
    if download_dir and download_dir ~= '' then
        return Files.rtrimSlashes(download_dir)
    end
    return DownloadService.getDefaultDownloadDir()
end

---Get the local file of a downloaded bookmark, if it still exists
---@param bookmark_id string
---@return string|nil
function DownloadService:getDownloadedPath(bookmark_id)
    local entry = self.index:readSetting(bookmark_id)
    if entry and entry.path and lfs.attributes(entry.path, 'mode') == 'file' then
        return entry.path
    end
    return nil
end

---Choose where to save a bookmark. Re-downloads overwrite the previous file so
---KOReader keeps the reading position.
---@param bookmark_id string
---@param title string
---@param ext string File extension, without dot
---@return string
function DownloadService:getTargetPath(bookmark_id, title, ext)
    local previous_path = self:getDownloadedPath(bookmark_id)
    if previous_path and previous_path:sub(-#ext - 1):lower() == '.' .. ext then
        return previous_path
    end

    local dir = self:getDownloadDir()
    local filename = util.getSafeFilename(title .. '.' .. ext, dir, FILENAME_TITLE_LIMIT)
    local path = dir .. '/' .. filename
    if lfs.attributes(path, 'mode') then
        -- A different file with the same name already exists
        local suffix = ' (' .. bookmark_id:sub(1, 8) .. ').' .. ext
        filename = util.getSafeFilename(title, dir, FILENAME_TITLE_LIMIT) .. suffix
        path = dir .. '/' .. filename
    end
    return path
end

---Write binary content to a file, replacing it only once fully written
---@param path string
---@param content string
---@return boolean|nil success, Error|nil error
local function writeFile(path, content)
    local tmp_path = path .. '.tmp'
    local file, open_err = io.open(tmp_path, 'wb')
    if not file then
        return nil, Error.new(T(_('Could not write file: %1'), tostring(open_err)))
    end
    local written, write_err = file:write(content)
    file:close()
    if not written then
        os.remove(tmp_path)
        return nil, Error.new(T(_('Could not write file: %1'), tostring(write_err)))
    end
    local renamed = os.rename(tmp_path, path)
    if not renamed then
        os.remove(path)
        renamed = os.rename(tmp_path, path)
    end
    if not renamed then
        os.remove(tmp_path)
        return nil, Error.new(T(_('Could not write file: %1'), path))
    end
    return true, nil
end

---Download an image from the web (no credentials are sent)
---@param url string
---@return string|nil content, string|nil content_type
local function fetchExternalImage(url)
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local ok, code, headers = pcall(function()
        return socket.skip(
            1,
            http.request({
                url = url,
                method = 'GET',
                headers = {
                    ['User-Agent'] = 'Mozilla/5.0 (KOReader)',
                    ['Accept'] = 'image/*,*/*;q=0.8',
                },
                sink = socketutil.table_sink(sink),
            })
        )
    end)
    socketutil:reset_timeout()

    if not ok or code ~= 200 or not headers then
        logger.info(
            '[Karakeep:Download] Image download failed:',
            url,
            ok and code or tostring(code)
        )
        return nil
    end
    return table.concat(sink), headers['content-type']
end

---Convert a plain text (or markdown) note to simple HTML paragraphs
---@param text string
---@return string
local function textToHtml(text)
    text = text:gsub('\r\n?', '\n'):gsub('[ \t]+\n', '\n')
    local paragraphs = {}
    for block in (text .. '\n\n'):gmatch('(.-)\n\n+') do
        block = util.trim(block)
        if block ~= '' then
            local escaped = util.htmlEscape(block):gsub('\n', '<br/>')
            table.insert(paragraphs, '<p>' .. escaped .. '</p>')
        end
    end
    return table.concat(paragraphs, '\n')
end

---Download the HTML content of a link bookmark
---@param content table Bookmark content
---@return string|nil html
function DownloadService:getLinkHtml(content)
    local html = str(content.htmlContent)
    if html then
        return html
    end
    -- Large articles may be stored as an asset instead of inline
    if str(content.contentAssetId) then
        local asset = self.ui.karakeep_api:getAsset(content.contentAssetId)
        return asset and str(asset.body)
    end
    return nil
end

---@param bookmark BookmarkResponse
---@param title string
---@param html string
---@param source_url string|nil
---@return string|nil path, Error|nil error, boolean|nil cancelled
function DownloadService:saveAsEpub(bookmark, title, html, source_url)
    local content = BookmarkFields.getContent(bookmark)
    local path = self:getTargetPath(bookmark.id, title, 'epub')

    local fetch_cover
    if str(content.imageAssetId) then
        fetch_cover = function()
            local asset = self.ui.karakeep_api:getAsset(content.imageAssetId)
            if asset then
                return asset.body, asset.content_type
            end
        end
    elseif str(content.imageUrl) then
        fetch_cover = function()
            return fetchExternalImage(content.imageUrl)
        end
    end

    local ok, err, cancelled = EpubBuilder.build({
        path = path,
        identifier = 'urn:karakeep:' .. bookmark.id,
        title = title,
        author = str(content.author) or str(content.publisher),
        source_url = str(source_url),
        description = str(content.description),
        date = str(content.datePublished),
        html = html,
        fetch_image = fetchExternalImage,
        fetch_cover = fetch_cover,
        on_progress = function(done, total)
            return Trapper:info(T(_('Downloading images… %1 / %2'), done, total))
        end,
    })
    if not ok then
        return nil, err, cancelled
    end
    return path, nil
end

---@param bookmark BookmarkResponse
---@param title string
---@param asset_id string
---@param ext string|nil File extension; detected from the content when nil
---@return string|nil path, Error|nil error
function DownloadService:saveAsset(bookmark, title, asset_id, ext)
    Trapper:info(_('Downloading file…'))
    local asset, err = self.ui.karakeep_api:getAsset(asset_id)
    if not asset then
        return nil, err
    end
    if not ext then
        local file_name = str(BookmarkFields.getContent(bookmark).fileName)
        ext = EpubBuilder.detectImageExtension(asset.body, asset.content_type)
            or (file_name and file_name:match('%.(%w+)$'))
            or 'bin'
        ext = ext:lower()
    end
    -- Don't end up with "file.pdf.pdf" when the title is a file name
    title = title:gsub('%.' .. ext .. '$', '')

    local path = self:getTargetPath(bookmark.id, title, ext)
    local ok, write_err = writeFile(path, asset.body)
    if not ok then
        return nil, write_err
    end
    return path, nil
end

---Download a bookmark for offline reading.
---Must be called from within `Trapper:wrap()`, which is used to show progress
---and lets the user interrupt the download.
---@param bookmark_id string
---@return string|nil path, string|nil error_message (both nil when cancelled)
function DownloadService:downloadBookmark(bookmark_id)
    Trapper:setPausedText(_('Download paused.'), _('Cancel download'), _('Continue'))
    Trapper:info(_('Fetching bookmark…'))

    local bookmark, err = self.ui.karakeep_api:getBookmark(bookmark_id, {
        query = { includeContent = true },
    })
    if not bookmark then
        return nil, err and err.message or _('Could not fetch bookmark')
    end

    local dir = self:getDownloadDir()
    util.makePath(dir)
    if lfs.attributes(dir, 'mode') ~= 'directory' then
        return nil, T(_('Could not create download folder: %1'), dir)
    end

    local content = BookmarkFields.getContent(bookmark)
    local title = BookmarkFields.getTitle(bookmark)
    local path, save_err, cancelled

    if content.type == 'link' then
        Trapper:info(_('Fetching article…'))
        local html = self:getLinkHtml(content)
        if html then
            path, save_err, cancelled = self:saveAsEpub(bookmark, title, html, content.url)
        elseif str(content.pdfAssetId) then
            path, save_err = self:saveAsset(bookmark, title, content.pdfAssetId, 'pdf')
        else
            return nil,
                _(
                    'This bookmark has no readable content yet. Karakeep may still be fetching the page.'
                )
        end
    elseif content.type == 'text' then
        local html = textToHtml(str(content.text) or '')
        path, save_err, cancelled = self:saveAsEpub(bookmark, title, html, str(content.sourceUrl))
    elseif content.type == 'asset' and str(content.assetId) then
        local ext = content.assetType == 'pdf' and 'pdf' or nil
        path, save_err = self:saveAsset(bookmark, title, content.assetId, ext)
    else
        return nil, _('This type of bookmark cannot be downloaded.')
    end

    if cancelled then
        return nil, nil
    end
    if not path then
        return nil, save_err and save_err.message or _('Download failed')
    end

    self.index:saveSetting(bookmark_id, {
        path = path,
        title = title,
        downloaded_at = os.time(),
    })
    self.index:flush()
    logger.info('[Karakeep:Download] Saved bookmark', bookmark_id, 'to', path)
    return path, nil
end

return DownloadService
