local DocSettings = require('docsettings')
local EventListener = require('ui/widget/eventlistener')
local JSON = require('json')
local LuaSettings = require('luasettings')
local NetworkMgr = require('ui/network/manager')
local UIManager = require('ui/uimanager')
local lfs = require('libs/libkoreader-lfs')
local logger = require('logger')
local _ = require('gettext')
local N_ = _.ngettext
local T = require('ffi/util').template

local BookmarkFields = require('karakeep/shared/bookmark_fields')
local HtmlText = require('karakeep/features/highlights/html_text')
local Notification = require('karakeep/shared/widgets/notification')

local str = BookmarkFields.str

-- Wait a bit after a change, so quick successive edits are sent together
local SYNC_DELAY_SECONDS = 3

-- KOReader highlight colors -> the four colors Karakeep supports
local KARAKEEP_COLORS = {
    yellow = 'yellow',
    gray = 'yellow',
    orange = 'red',
    red = 'red',
    green = 'green',
    olive = 'green',
    cyan = 'blue',
    blue = 'blue',
    purple = 'blue',
}

---@class SyncedHighlight
---@field id string|nil Karakeep highlight id, nil when the text wasn't found in the article
---@field text string Highlighted text when it was last synced
---@field color string|nil
---@field note string|nil

---@class HighlightSyncEntry
---@field pending boolean|nil Some changes haven't been sent yet
---@field unsupported boolean|nil The bookmark can't have highlights in Karakeep
---@field synced table<string, SyncedHighlight> Keyed by KOReader annotation key

---@class HighlightSyncResult
---@field added number
---@field updated number
---@field deleted number
---@field unmatched number Highlights that couldn't be found in the Karakeep article
---@field new_unmatched number Of which found unmatched during this sync
---@field failed number Changes that couldn't be sent (retried on next sync)
---@field unsupported boolean|nil

-- **HighlightSync** - Mirrors KOReader highlights of downloaded articles to
-- highlights on the Karakeep bookmark: new highlights are created, note and
-- color changes updated, and deleted highlights deleted. Changes that can't be
-- sent (e.g. offline) are kept pending and sent on the next sync.
---@class HighlightSync : EventListener
---@field ui UI
---@field data_dir string
---@field store LuaSettings Bookmark id -> HighlightSyncEntry
---@field bookmark_id string|nil Bookmark of the open document, if downloaded from Karakeep
local HighlightSync = EventListener:extend({})

function HighlightSync:init()
    self.store = LuaSettings:open(self.data_dir .. 'highlights.lua')
    self.sync_task = function()
        self:autoSync()
    end
end

---@param annotation table KOReader annotation
---@return boolean
local function isHighlight(annotation)
    return annotation.drawer ~= nil
        and type(annotation.pos0) == 'string'
        and str(annotation.text) ~= nil
end

---Key of an annotation: creation time (seconds) plus start position, as two
---highlights may be created within the same second. Extending a highlight
---changes its start, which re-creates it: Karakeep can't move highlights anyway.
---@param annotation table
---@return string
local function annotationKey(annotation)
    return (annotation.datetime or '') .. '|' .. annotation.pos0
end

---@param value any
---@return any value or JSON null
local function orNull(value)
    if value == nil then
        return JSON.util.null
    end
    return value
end

---@param bookmark_id string
---@return HighlightSyncEntry
function HighlightSync:getEntry(bookmark_id)
    local entry = self.store:readSetting(bookmark_id)
    if type(entry) ~= 'table' then
        entry = {}
    end
    entry.synced = entry.synced or {}
    return entry
end

---@param bookmark_id string
---@param entry HighlightSyncEntry
function HighlightSync:saveEntry(bookmark_id, entry)
    self.store:saveSetting(bookmark_id, entry)
    self.store:flush()
end

-- =============================================================================
-- Sync
-- =============================================================================

---Fetch the article from Karakeep and index its text
---@param bookmark_id string
---@return HtmlTextIndex|nil index, boolean|nil unsupported
function HighlightSync:loadArticle(bookmark_id)
    local bookmark, err = self.ui.karakeep_api:getBookmark(bookmark_id, {
        query = { includeContent = true },
    })
    if not bookmark then
        logger.warn(
            '[Karakeep:Highlights] Could not fetch bookmark',
            bookmark_id,
            err and err.message
        )
        return nil
    end
    local content = BookmarkFields.getContent(bookmark)
    if content.type ~= 'link' then
        return nil, true
    end
    local html = self.ui.karakeep_downloader:getLinkHtml(content)
    if not html then
        logger.warn('[Karakeep:Highlights] No article content for bookmark', bookmark_id)
        return nil
    end
    return HtmlText.buildIndex(HtmlText.extract(html))
end

---Send the changes between KOReader highlights and what was last synced
---@param bookmark_id string
---@param annotations table[] KOReader annotations of the document
---@param page_count number|nil Pages in the document, to tell apart repeated text
---@param get_text? fun(annotation: table): string Text to look for in the article
---@return HighlightSyncResult
function HighlightSync:syncBookmark(bookmark_id, annotations, page_count, get_text)
    local api = self.ui.karakeep_api
    local entry = self:getEntry(bookmark_id)
    local synced = entry.synced
    local result =
        { added = 0, updated = 0, deleted = 0, unmatched = 0, new_unmatched = 0, failed = 0 }

    if entry.unsupported then
        result.unsupported = true
        return result
    end

    local current = {}
    for _, annotation in ipairs(annotations) do
        if isHighlight(annotation) then
            current[annotationKey(annotation)] = annotation
        end
    end

    -- Highlights deleted in KOReader
    for key, synced_highlight in pairs(synced) do
        if not current[key] then
            if synced_highlight.id then
                local ok, err = api:deleteHighlight(synced_highlight.id)
                if ok or (err and err.status == 404) then
                    synced[key] = nil
                    result.deleted = result.deleted + 1
                else
                    result.failed = result.failed + 1
                end
            else
                synced[key] = nil
            end
        end
    end

    -- The article is only fetched when a highlight has to be located
    local article, article_loaded
    local function getArticle()
        if not article_loaded then
            article_loaded = true
            local unsupported
            article, unsupported = self:loadArticle(bookmark_id)
            if unsupported then
                entry.unsupported = true
                result.unsupported = true
            end
        end
        return article
    end

    for key, annotation in pairs(current) do
        ---@type SyncedHighlight|nil
        local synced_highlight = synced[key]
        local color = KARAKEEP_COLORS[annotation.color or ''] or 'yellow'
        local note = str(annotation.note)

        -- Note or color changed
        if
            synced_highlight
            and synced_highlight.id
            and synced_highlight.text == annotation.text
            and (synced_highlight.color ~= color or synced_highlight.note ~= note)
        then
            local ok, err = api:updateHighlight(synced_highlight.id, {
                body = { color = color, note = orNull(note) },
            })
            if ok then
                synced_highlight.color = color
                synced_highlight.note = note
                result.updated = result.updated + 1
            elseif err and err.status == 404 then
                -- Deleted in Karakeep: create it again
                synced[key] = nil
                synced_highlight = nil
            else
                result.failed = result.failed + 1
            end
        end

        -- New highlight, or its text changed (Karakeep can't move a highlight)
        if not synced_highlight or synced_highlight.text ~= annotation.text then
            local replaced_ok = true
            if synced_highlight and synced_highlight.id then
                local ok, err = api:deleteHighlight(synced_highlight.id)
                replaced_ok = ok ~= nil or (err ~= nil and err.status == 404)
            end

            local index = replaced_ok and getArticle()
            if not replaced_ok or (not index and not result.unsupported) then
                result.failed = result.failed + 1
            elseif index then
                local position
                if annotation.pageno and page_count and page_count > 0 then
                    position = (annotation.pageno - 0.5) / page_count
                end
                local text = get_text and get_text(annotation) or annotation.text
                local start_offset, end_offset = HtmlText.locate(index, text, position)
                if not start_offset or not end_offset then
                    synced[key] = { text = annotation.text }
                    result.new_unmatched = result.new_unmatched + 1
                else
                    local created = api:createHighlight({
                        body = {
                            bookmarkId = bookmark_id,
                            startOffset = start_offset,
                            endOffset = end_offset,
                            color = color,
                            text = annotation.text,
                            note = orNull(note),
                        },
                    })
                    if created and str(created.id) then
                        synced[key] =
                            { id = created.id, text = annotation.text, color = color, note = note }
                        result.added = result.added + 1
                    else
                        synced[key] = nil
                        result.failed = result.failed + 1
                    end
                end
            end
        end

        if synced[key] and not synced[key].id then
            result.unmatched = result.unmatched + 1
        end
    end

    entry.pending = result.failed > 0 or nil
    if entry.unsupported then
        entry.pending = nil
    end
    self:saveEntry(bookmark_id, entry)
    logger.info('[Karakeep:Highlights] Synced', bookmark_id, result)
    return result
end

---Sync the open document
---@return HighlightSyncResult|nil
function HighlightSync:syncOpenDocument()
    local document = self.ui.document
    if not self.bookmark_id or not document then
        return nil
    end
    ---@type table[]
    local annotations = self.ui.annotation and self.ui.annotation.annotations or {}
    return self:syncBookmark(
        self.bookmark_id,
        annotations,
        document:getPageCount(),
        function(annotation)
            -- An edited highlight text isn't in the article: use the document's text
            if annotation.text_edited and annotation.pos0 and annotation.pos1 then
                local text = document:getTextFromXPointers(annotation.pos0, annotation.pos1)
                return str(text) or annotation.text
            end
            return annotation.text
        end
    )
end

---Sync a document that isn't open, from its saved annotations.
---Documents without saved annotations (or that no longer exist) are left
---alone, so their Karakeep highlights are never deleted by mistake.
---@param bookmark_id string
---@param path string
---@return HighlightSyncResult|nil
function HighlightSync:syncClosedDocument(bookmark_id, path)
    if lfs.attributes(path, 'mode') ~= 'file' or not DocSettings:hasSidecarFile(path) then
        return nil
    end
    local doc_settings = DocSettings:open(path)
    local annotations = doc_settings:readSetting('annotations')
    if type(annotations) ~= 'table' then
        return nil
    end
    return self:syncBookmark(bookmark_id, annotations, doc_settings:readSetting('doc_pages'))
end

---Whether a download can have highlights in Karakeep
---@param bookmark_id string
---@param download DownloadEntry
---@return boolean
function HighlightSync:canSyncDownload(bookmark_id, download)
    -- Downloads made before the bookmark type was recorded are checked on sync
    if download.kind and download.kind ~= 'link' then
        return false
    end
    return download.path:lower():match('%.epub$') ~= nil
        and not self:getEntry(bookmark_id).unsupported
end

---Sync downloaded documents
---@param pending_only boolean Only documents with changes not sent yet
---@return HighlightSyncResult
function HighlightSync:syncDownloads(pending_only)
    local total =
        { added = 0, updated = 0, deleted = 0, unmatched = 0, new_unmatched = 0, failed = 0 }
    for bookmark_id, download in pairs(self.ui.karakeep_downloader:getDownloads()) do
        if
            self:canSyncDownload(bookmark_id, download)
            and (not pending_only or self:getEntry(bookmark_id).pending)
        then
            local result
            if bookmark_id == self.bookmark_id and self.ui.document then
                result = self:syncOpenDocument()
            else
                result = self:syncClosedDocument(bookmark_id, download.path)
            end
            if result then
                for key, value in pairs(result) do
                    if type(value) == 'number' then
                        total[key] = total[key] + value
                    end
                end
            end
        end
    end
    return total
end

-- =============================================================================
-- Automatic sync
-- =============================================================================

---Find the Karakeep bookmark of the open document
---@return string|nil
function HighlightSync:findOpenDocumentBookmark()
    local document = self.ui.document
    if not document or not document.file then
        return nil
    end
    local downloader = self.ui.karakeep_downloader
    local bookmark_id = downloader:getBookmarkIdForPath(document.file)
    if bookmark_id then
        return bookmark_id
    end
    -- The file may have been moved: our EPUBs carry the bookmark id
    local props = document:getProps()
    local identifiers = props and props.identifiers
    bookmark_id = type(identifiers) == 'string' and identifiers:match('urn:karakeep:([%w_-]+)')
    if bookmark_id and downloader:getDownload(bookmark_id) then
        downloader:updatePath(bookmark_id, document.file)
        return bookmark_id
    end
    return nil
end

function HighlightSync:onReaderReady()
    self.bookmark_id = self:findOpenDocumentBookmark()
    if self.bookmark_id then
        local download = self.ui.karakeep_downloader:getDownload(self.bookmark_id)
        if not download or not self:canSyncDownload(self.bookmark_id, download) then
            self.bookmark_id = nil
        elseif self:getEntry(self.bookmark_id).pending then
            self:scheduleSync()
        end
    end
end

function HighlightSync:onAnnotationsModified()
    if not self.bookmark_id then
        return
    end
    local entry = self:getEntry(self.bookmark_id)
    if entry.unsupported then
        return
    end
    entry.pending = true
    self:saveEntry(self.bookmark_id, entry)
    self:scheduleSync()
end

function HighlightSync:scheduleSync()
    UIManager:unschedule(self.sync_task)
    UIManager:scheduleIn(SYNC_DELAY_SECONDS, self.sync_task)
end

---Sync in the background, without asking to turn on Wi-Fi
function HighlightSync:autoSync()
    if not self.bookmark_id or not NetworkMgr:isConnected() then
        return
    end
    local result = self:syncOpenDocument()
    if result and result.new_unmatched > 0 then
        Notification:warning(
            T(
                N_(
                    'This highlight could not be found in the Karakeep article, so it was not synced.',
                    '%1 highlights could not be found in the Karakeep article, so they were not synced.',
                    result.new_unmatched
                ),
                result.new_unmatched
            )
        )
    end
end

function HighlightSync:onCloseDocument()
    UIManager:unschedule(self.sync_task)
    if
        self.bookmark_id
        and self:getEntry(self.bookmark_id).pending
        and NetworkMgr:isConnected()
    then
        self:syncOpenDocument()
    end
end

function HighlightSync:onNetworkConnected()
    -- Network is up: send changes made while offline
    UIManager:scheduleIn(1, function()
        self:syncDownloads(true)
    end)
end

-- =============================================================================
-- Manual sync
-- =============================================================================

---@param result HighlightSyncResult
---@return string
function HighlightSync.describeResult(result)
    if result.unsupported and result.added + result.updated + result.deleted == 0 then
        return _('Karakeep only supports highlights on web articles.')
    end
    local lines = {}
    if result.added + result.updated + result.deleted > 0 then
        table.insert(
            lines,
            T(
                _('Highlights sent to Karakeep: %1 new, %2 updated, %3 deleted.'),
                result.added,
                result.updated,
                result.deleted
            )
        )
    end
    if result.unmatched > 0 then
        table.insert(
            lines,
            T(
                N_(
                    '1 highlight could not be found in the Karakeep article.',
                    '%1 highlights could not be found in the Karakeep article.',
                    result.unmatched
                ),
                result.unmatched
            )
        )
    end
    if result.failed > 0 then
        table.insert(
            lines,
            T(
                N_(
                    '1 change could not be sent and will be retried.',
                    '%1 changes could not be sent and will be retried.',
                    result.failed
                ),
                result.failed
            )
        )
    end
    if #lines == 0 then
        return _('Highlights are up to date.')
    end
    return table.concat(lines, '\n')
end

---Sync now: the open document, or all downloaded articles from the file browser
function HighlightSync:syncNow()
    NetworkMgr:runWhenOnline(function()
        local loading = Notification:info(_('Syncing highlights…'))
        local result
        if self.ui.document then
            result = self:syncOpenDocument()
        else
            result = self:syncDownloads(false)
        end
        loading:close()
        if result then
            local notify = result.failed > 0 and Notification.warning or Notification.success
            notify(Notification, HighlightSync.describeResult(result), { timeout = 4 })
        end
    end)
end

---Get the "Sync highlights" menu item
---@return table
function HighlightSync:getMenuItem()
    return {
        text = _('Sync highlights to Karakeep'),
        enabled_func = function()
            -- In the reader, only for articles downloaded from Karakeep
            return not self.ui.document or self.bookmark_id ~= nil
        end,
        callback = function()
            self:syncNow()
        end,
    }
end

return HighlightSync
