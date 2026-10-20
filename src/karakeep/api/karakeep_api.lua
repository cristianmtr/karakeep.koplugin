local EventListener = require('ui/widget/eventlistener')

local HttpClient = require('karakeep/shared/http_client')

---@class KarakeepAPI : EventListener
---@field server_address string Server address for API calls
---@field api_token string API token for authentication
---@field api_base string API base URL
---@field api_client HttpClient Generic HTTP API client
local KarakeepAPI = EventListener:extend({})

---Create a new HttpClient instance
---@param config HttpClientConfig
---@return HttpClient
local function createHttpClient(config)
    return HttpClient:new({
        server_address = config.server_address,
        api_token = config.api_token,
        api_base = config.api_base,
    })
end

---Initialize the API instance with configuration
function KarakeepAPI:init()
    self.api_client = createHttpClient({
        server_address = self.server_address,
        api_token = self.api_token,
        api_base = self.api_base,
    })
end

---Handle server configuration change event
---@param args {api_token: string, server_address: string} New server configuration
function KarakeepAPI:onServerConfigChange(args)
    self.api_token = args.api_token
    self.server_address = args.server_address

    -- Recreate HttpClient with new settings
    self.api_client = createHttpClient({
        server_address = self.server_address,
        api_token = self.api_token,
        api_base = self.api_base,
    })
end

-- =============================================================================
-- Bookmarks
-- =============================================================================

---@alias CrawlPriority 'low' | 'normal'

---@class BookmarkRequestBase
---@field title? string
---@field archived? boolean
---@field favourited? boolean
---@field note? string
---@field summary? string
---@field createdAt? string
---@field crawlPriority? CrawlPriority

---@class BookmarkRequestLink : BookmarkRequestBase
---@field type 'link'
---@field url string
---@field precrawledArchiveId? number

---@class BookmarkRequestText : BookmarkRequestBase
---@field type 'text'
---@field text string
---@field sourceUrl? string

---@class BookmarkRequestAsset : BookmarkRequestBase
---@field type 'asset'
---@field assetType 'image' | 'pdf'
---@field assetId string
---@field fileName? string
---@field sourceUrl? string

---@class BookmarkContentLink
---@field type 'link'
---@field url string
---@field title string|nil
---@field description string|nil
---@field imageUrl string|nil
---@field imageAssetId string|nil
---@field screenshotAssetId string|nil
---@field pdfAssetId string|nil
---@field fullPageArchiveAssetId string|nil
---@field precrawledArchiveAssetId string|nil
---@field videoAssetId string|nil
---@field favicon string|nil
---@field htmlContent string|nil
---@field contentAssetId string|nil
---@field crawledAt string|nil
---@field author string|nil
---@field publisher string|nil
---@field datePublished string|nil
---@field dateModified string|nil

---@class BookmarkContentText
---@field type 'text'
---@field text string
---@field sourceUrl string|nil

---@class BookmarkContentAsset
---@field type 'asset'
---@field assetType 'image'|'pdf'
---@field assetId string
---@field fileName string|nil
---@field sourceUrl string|nil
---@field size number|nil
---@field content string|nil

---@class BookmarkContentUnknown
---@field type 'unknown'

---@alias BookmarkContent BookmarkContentLink | BookmarkContentText | BookmarkContentAsset | BookmarkContentUnknown

---@class BookmarkResponse
---@field id string
---@field createdAt string
---@field modifiedAt string|nil
---@field title string|nil
---@field archived boolean
---@field favourited boolean
---@field taggingStatus "success"|"failure"|"pending"|nil
---@field summarizationStatus "success"|"failure"|"pending"|nil
---@field note string|nil
---@field summary string|nil
---@field tags table[] Array of tag objects
---@field content BookmarkContent Content object with type-specific fields
---@field assets table[] Array of asset objects

---@alias BookmarkRequest BookmarkRequestLink | BookmarkRequestText | BookmarkRequestAsset

---Create a new bookmark
---@param config HttpClientOptions<BookmarkRequest, QueryParam[]>
---@return table|nil result, Error|nil error
function KarakeepAPI:createNewBookmark(config)
    return self.api_client:post('/bookmarks', config)
end

---Update an existing bookmark
---@param bookmark_id string The bookmark ID to update
---@param config HttpClientOptions<BookmarkRequest, QueryParam[]>
---@return table|nil result, Error|nil error
function KarakeepAPI:updateBookmark(bookmark_id, config)
    return self.api_client:patch('/bookmarks/' .. bookmark_id, config)
end

---@class PaginatedBookmarksResponse
---@field bookmarks BookmarkResponse[]
---@field nextCursor string|nil Cursor for the next page (JSON null when there are no more pages)

---@class BookmarkListQuery
---@field archived? boolean
---@field favourited? boolean
---@field limit? number
---@field cursor? string
---@field includeContent? boolean

---Get a page of bookmarks
---@param config HttpClientOptions<nil, BookmarkListQuery>
---@return PaginatedBookmarksResponse|nil result, Error|nil error
function KarakeepAPI:getBookmarks(config)
    return self.api_client:get('/bookmarks', config)
end

---Search bookmarks (query goes in `q`)
---@param config HttpClientOptions<nil, BookmarkListQuery|{q: string}>
---@return PaginatedBookmarksResponse|nil result, Error|nil error
function KarakeepAPI:searchBookmarks(config)
    return self.api_client:get('/bookmarks/search', config)
end

---Get a single bookmark
---@param bookmark_id string
---@param config? HttpClientOptions<nil, {includeContent?: boolean}>
---@return BookmarkResponse|nil result, Error|nil error
function KarakeepAPI:getBookmark(bookmark_id, config)
    return self.api_client:get('/bookmarks/' .. bookmark_id, config)
end

-- =============================================================================
-- Lists
-- =============================================================================

---@class ListResponse
---@field id string
---@field name string
---@field icon string
---@field parentId string|nil

---Get all lists of the user
---@param config? HttpClientOptions<nil, QueryParam[]>
---@return {lists: ListResponse[]}|nil result, Error|nil error
function KarakeepAPI:getLists(config)
    return self.api_client:get('/lists', config)
end

---Get a page of bookmarks in a list
---@param list_id string
---@param config HttpClientOptions<nil, BookmarkListQuery>
---@return PaginatedBookmarksResponse|nil result, Error|nil error
function KarakeepAPI:getListBookmarks(list_id, config)
    return self.api_client:get('/lists/' .. list_id .. '/bookmarks', config)
end

-- =============================================================================
-- Highlights
-- =============================================================================

---@alias HighlightColor 'yellow' | 'red' | 'green' | 'blue'

---Offsets are UTF-16 code unit offsets into the text of the bookmark's
---reader view HTML (all its text nodes concatenated).
---`text` and `note` are required by the API but may be JSON null.
---@class HighlightRequest
---@field bookmarkId string
---@field startOffset number
---@field endOffset number
---@field color HighlightColor
---@field text string|table Highlighted text (or JSON null)
---@field note string|table Note (or JSON null)

---@class HighlightResponse : HighlightRequest
---@field id string
---@field createdAt string

---Create a highlight on a link bookmark
---@param config HttpClientOptions<HighlightRequest, QueryParam[]>
---@return HighlightResponse|nil result, Error|nil error
function KarakeepAPI:createHighlight(config)
    return self.api_client:post('/highlights', config)
end

---Update the color and/or note of a highlight (offsets can't be changed)
---@param highlight_id string
---@param config HttpClientOptions<{color?: HighlightColor, note?: string|table}, QueryParam[]>
---@return HighlightResponse|nil result, Error|nil error
function KarakeepAPI:updateHighlight(highlight_id, config)
    return self.api_client:patch('/highlights/' .. highlight_id, config)
end

---Delete a highlight
---@param highlight_id string
---@param config? HttpClientOptions<nil, QueryParam[]>
---@return table|nil result, Error|nil error
function KarakeepAPI:deleteHighlight(highlight_id, config)
    return self.api_client:delete('/highlights/' .. highlight_id, config)
end

-- =============================================================================
-- Assets
-- =============================================================================

---Download an asset's binary content
---@param asset_id string
---@param config? HttpClientOptions<nil, QueryParam[]>
---@return RawResponse|nil result, Error|nil error
function KarakeepAPI:getAsset(asset_id, config)
    config = config or {}
    config.raw = true
    return self.api_client:get('/assets/' .. asset_id, config)
end

return KarakeepAPI
