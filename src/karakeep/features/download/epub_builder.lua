local lfs = require('libs/libkoreader-lfs')
local logger = require('logger')
local socket_url = require('socket.url')
local util = require('util')

local Error = require('karakeep/shared/error')

-- **EpubBuilder** - Packs an HTML article (and the images it references)
-- into a single EPUB file, so it can be read offline.
local EpubBuilder = {}

---@alias ImageFetcher fun(url: string): string|nil content, string|nil content_type

---@class EpubBuildOptions
---@field path string Final .epub path
---@field identifier string Unique book identifier
---@field title string
---@field author? string
---@field source_url? string Original URL, also used to resolve relative image URLs
---@field description? string
---@field date? string
---@field html string Article body (HTML fragment)
---@field fetch_image ImageFetcher Downloads an image
---@field fetch_cover? fun(): string|nil, string|nil Downloads the cover image
---@field on_progress? fun(done: number, total: number): boolean Return false to cancel

-- Image formats crengine can render, by file extension
local IMAGE_MIMETYPES = {
    jpg = 'image/jpeg',
    png = 'image/png',
    gif = 'image/gif',
    webp = 'image/webp',
    svg = 'image/svg+xml',
}

local CONTENT_TYPE_EXTENSIONS = {
    ['image/jpeg'] = 'jpg',
    ['image/jpg'] = 'jpg',
    ['image/pjpeg'] = 'jpg',
    ['image/png'] = 'png',
    ['image/gif'] = 'gif',
    ['image/webp'] = 'webp',
    ['image/svg+xml'] = 'svg',
}

local STYLESHEET = [[
img { max-width: 100%; }
figure { margin: 1em 0; }
figcaption { font-size: 0.85em; font-style: italic; }
.karakeep-meta { font-size: 0.85em; margin-bottom: 1.5em; }
]]

-- =============================================================================
-- Zip writer
-- =============================================================================

---@class EpubZip
---@field add fun(self: EpubZip, name: string, content: string, no_compression?: boolean): boolean|nil
---@field close fun(self: EpubZip)

---Open a zip file for writing. KOReader replaced `ffi/zipwriter` with
---`ffi/archiver` after v2025.04, so support both.
---@param path string
---@return EpubZip|nil
local function openZip(path)
    local has_archiver, Archiver = pcall(require, 'ffi/archiver')
    if has_archiver and type(Archiver) == 'table' and Archiver.Writer then
        local writer = Archiver.Writer:new()
        if not writer:open(path, 'epub') then
            return nil
        end
        return {
            add = function(_self, name, content, no_compression)
                writer:setZipCompression(no_compression and 'store' or 'deflate')
                return writer:addFileFromMemory(name, content)
            end,
            close = function(_self)
                writer:close()
            end,
        }
    end

    local ZipWriter = require('ffi/zipwriter')
    local writer = ZipWriter:new()
    if not writer:open(path) then
        return nil
    end
    return {
        add = function(_self, name, content, no_compression)
            writer:add(name, content, no_compression)
            return true
        end,
        close = function(_self)
            writer:close()
        end,
    }
end

-- =============================================================================
-- HTML helpers
-- =============================================================================

---@param text string|nil
---@return string
local function escape(text)
    -- Parentheses drop gsub's second return value (the substitution count)
    return (util.htmlEscape(text or ''))
end

---Detect an image format from its first bytes, falling back to the Content-Type header
---@param content string
---@param content_type string|nil
---@return string|nil extension
function EpubBuilder.detectImageExtension(content, content_type)
    if content:sub(1, 3) == '\255\216\255' then
        return 'jpg'
    elseif content:sub(1, 8) == '\137PNG\r\n\26\n' then
        return 'png'
    elseif content:sub(1, 4) == 'GIF8' then
        return 'gif'
    elseif content:sub(1, 4) == 'RIFF' and content:sub(9, 12) == 'WEBP' then
        return 'webp'
    end
    if content_type then
        local mime = content_type:match('^%s*([^;%s]+)')
        if mime then
            return CONTENT_TYPE_EXTENSIONS[mime:lower()]
        end
    end
    return nil
end

---Get the value of an attribute from an HTML tag
---@param tag string
---@param name string
---@return string|nil
local function getAttribute(tag, name)
    local value = tag:match('%s' .. name .. '%s*=%s*"([^"]*)"')
        or tag:match('%s' .. name .. "%s*=%s*'([^']*)'")
    return value
end

---Resolve the URL of an <img> tag to an absolute http(s) URL
---@param tag string The <img ...> tag
---@param base_url string|nil
---@return string|nil
function EpubBuilder.resolveImageUrl(tag, base_url)
    local src = getAttribute(tag, 'src')
    if not src or src == '' or src:sub(1, 5) == 'data:' then
        -- Lazy-loaded images keep the real URL in data-src
        src = getAttribute(tag, 'data%-src')
    end
    if not src or src == '' or src:sub(1, 5) == 'data:' then
        return nil
    end

    src = util.htmlEntitiesToUtf8(src)
    if src:sub(1, 2) == '//' then
        src = 'https:' .. src
    elseif not src:match('^%a[%w+.-]*:') then
        if not base_url then
            return nil
        end
        src = socket_url.absolute(base_url, src)
    end

    if not src:match('^https?://') then
        return nil
    end
    return src
end

---crengine serializes attribute values without escaping them. Replace double
---quotes inside attribute values by apostrophes beforehand, so they can't end
---the value early in the balanced output.
---@param html string
---@return string
local function protectAttributeQuotes(html)
    return (
        html:gsub('<[^>]+>', function(tag)
            tag = tag:gsub('&quot;', '&#39;'):gsub('&#0*34;', '&#39;'):gsub('&#[xX]0*22;', '&#39;')
            -- Single-quoted values may contain raw double quotes
            return (
                tag:gsub("=%s*'([^']*)'", function(value)
                    return "='" .. value:gsub('"', '&#39;') .. "'"
                end)
            )
        end)
    )
end

---Escape "&" not starting an entity inside tags (crengine outputs them raw,
---e.g. in link URLs), which is invalid XML.
---@param html string
---@return string
local function escapeAttributeAmpersands(html)
    return (
        html:gsub('<[^>]+>', function(tag)
            return (
                tag:gsub('&(#?%w*;?)', function(rest)
                    if rest:match('^#?%w+;$') then
                        return nil -- already an entity, keep it
                    end
                    return '&amp;' .. rest
                end)
            )
        end)
    )
end

---Turn an HTML fragment into a balanced (well-formed) XHTML document, which
---crengine requires for EPUB content.
---@param title string
---@param body string
---@return string
local function buildXhtml(title, body)
    local html = '<html><head><title></title></head><body>'
        .. protectAttributeQuotes(body)
        .. '</body></html>'

    -- crengine's HTML parser closes unclosed tags and fixes nesting
    local ok, cre = pcall(require, 'libs/libkoreader-cre')
    if ok and cre and cre.getBalancedHTML then
        local balanced_ok, balanced = pcall(cre.getBalancedHTML, html, 0)
        if balanced_ok and type(balanced) == 'string' then
            html = escapeAttributeAmpersands(balanced)
        else
            logger.warn('[Karakeep:EpubBuilder] Could not balance HTML, using it as is')
        end
    end

    local balanced_body = html:match('<body[^>]*>(.*)</body>') or body
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<!DOCTYPE html>\n',
        '<html xmlns="http://www.w3.org/1999/xhtml">\n',
        '<head>\n',
        '<title>',
        escape(title),
        '</title>\n',
        '<link rel="stylesheet" type="text/css" href="stylesheet.css"/>\n',
        '</head>\n',
        '<body>\n',
        balanced_body,
        '\n</body>\n',
        '</html>\n',
    })
end

---Build the article header: title, author and a link to the original
---@param opts EpubBuildOptions
---@return string
local function buildHeader(opts)
    local parts = { '<h1>', escape(opts.title), '</h1>' }
    local meta = {}
    if opts.author then
        table.insert(meta, escape(opts.author))
    end
    if opts.source_url then
        local host = opts.source_url:match('^%a[%w+.-]*://([^/:?#]+)') or opts.source_url
        table.insert(meta, ('<a href="%s">%s</a>'):format(escape(opts.source_url), escape(host)))
    end
    if #meta > 0 then
        table.insert(parts, '<p class="karakeep-meta">' .. table.concat(meta, ' · ') .. '</p>')
    end
    return table.concat(parts)
end

-- =============================================================================
-- EPUB files
-- =============================================================================

local CONTAINER_XML = [[
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
]]

---@param opts EpubBuildOptions
---@param images {id: string, href: string, mimetype: string}[]
---@param cover {id: string, href: string, mimetype: string}|nil
---@return string
local function buildContentOpf(opts, images, cover)
    local metadata = {
        ('<dc:title>%s</dc:title>'):format(escape(opts.title)),
        ('<dc:identifier id="bookid">%s</dc:identifier>'):format(escape(opts.identifier)),
    }
    if opts.author then
        table.insert(metadata, ('<dc:creator>%s</dc:creator>'):format(escape(opts.author)))
    end
    if opts.source_url then
        table.insert(metadata, ('<dc:source>%s</dc:source>'):format(escape(opts.source_url)))
    end
    if opts.description then
        table.insert(
            metadata,
            ('<dc:description>%s</dc:description>'):format(escape(opts.description))
        )
    end
    if opts.date then
        table.insert(metadata, ('<dc:date>%s</dc:date>'):format(escape(opts.date)))
    end
    if cover then
        table.insert(metadata, ('<meta name="cover" content="%s"/>'):format(cover.id))
    end

    local manifest = {
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
        '<item id="content" href="content.html" media-type="application/xhtml+xml"/>',
        '<item id="css" href="stylesheet.css" media-type="text/css"/>',
    }
    if cover then
        table.insert(
            manifest,
            ('<item id="%s" href="%s" media-type="%s"/>'):format(
                cover.id,
                cover.href,
                cover.mimetype
            )
        )
    end
    for _, image in ipairs(images) do
        table.insert(
            manifest,
            ('<item id="%s" href="%s" media-type="%s"/>'):format(
                image.id,
                image.href,
                image.mimetype
            )
        )
    end

    return table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/"',
        ' unique-identifier="bookid" version="2.0">\n',
        '  <metadata>\n    ',
        table.concat(metadata, '\n    '),
        '\n  </metadata>\n',
        '  <manifest>\n    ',
        table.concat(manifest, '\n    '),
        '\n  </manifest>\n',
        '  <spine toc="ncx">\n    <itemref idref="content"/>\n  </spine>\n',
        '</package>\n',
    })
end

---@param opts EpubBuildOptions
---@return string
local function buildTocNcx(opts)
    local title = escape(opts.title)
    return table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n',
        '  <head>\n',
        ('    <meta name="dtb:uid" content="%s"/>\n'):format(escape(opts.identifier)),
        '    <meta name="dtb:depth" content="1"/>\n',
        '    <meta name="dtb:totalPageCount" content="0"/>\n',
        '    <meta name="dtb:maxPageNumber" content="0"/>\n',
        '  </head>\n',
        ('  <docTitle><text>%s</text></docTitle>\n'):format(title),
        '  <navMap>\n',
        '    <navPoint id="navpoint-1" playOrder="1">\n',
        ('      <navLabel><text>%s</text></navLabel>\n'):format(title),
        '      <content src="content.html"/>\n',
        '    </navPoint>\n',
        '  </navMap>\n',
        '</ncx>\n',
    })
end

-- =============================================================================
-- Build
-- =============================================================================

---Build an EPUB file from an HTML article, downloading and embedding its images.
---Images that fail to download are dropped from the article.
---@param opts EpubBuildOptions
---@return boolean|nil success, Error|nil error, boolean|nil cancelled
function EpubBuilder.build(opts)
    -- Keep only the body when given a full HTML document
    local body = opts.html:match('<body[^>]*>(.*)</body>') or opts.html
    local xhtml = buildXhtml(opts.title, buildHeader(opts) .. body)

    -- Collect the unique image URLs, in document order
    local image_urls = {}
    local seen_urls = {}
    for tag in xhtml:gmatch('<img%s[^>]*>') do
        local url = EpubBuilder.resolveImageUrl(tag, opts.source_url)
        if url and not seen_urls[url] then
            seen_urls[url] = true
            table.insert(image_urls, url)
        end
    end

    local tmp_path = opts.path .. '.tmp'
    local zip = openZip(tmp_path)
    if not zip then
        return nil, Error.new('Could not create file: ' .. tmp_path)
    end

    local function abort(err, cancelled)
        zip:close()
        os.remove(tmp_path)
        return nil, err, cancelled
    end

    -- The mimetype file must come first and be stored uncompressed
    zip:add('mimetype', 'application/epub+zip', true)
    zip:add('META-INF/container.xml', CONTAINER_XML)

    -- Download images and add them to the archive as we go, to keep memory use low
    local images = {}
    local image_hrefs = {} -- url -> href inside the EPUB
    for i, url in ipairs(image_urls) do
        if opts.on_progress and not opts.on_progress(i - 1, #image_urls) then
            return abort(nil, true)
        end
        local content, content_type = opts.fetch_image(url)
        local ext = content and EpubBuilder.detectImageExtension(content, content_type)
        if ext then
            local id = ('img%03d'):format(#images + 1)
            local href = ('images/%s.%s'):format(id, ext)
            -- Images are already compressed (except SVG, which is text)
            zip:add('OEBPS/' .. href, content, ext ~= 'svg')
            table.insert(images, { id = id, href = href, mimetype = IMAGE_MIMETYPES[ext] })
            image_hrefs[url] = href
        else
            logger.info('[Karakeep:EpubBuilder] Skipping image', url)
        end
    end

    -- Point images to the embedded files, drop those that could not be downloaded
    xhtml = xhtml:gsub('<img%s[^>]*>', function(tag)
        local url = EpubBuilder.resolveImageUrl(tag, opts.source_url)
        local href = url and image_hrefs[url]
        if not href then
            return ''
        end
        -- crengine serializes attribute values unescaped, so normalize then escape
        local alt = util.htmlEntitiesToUtf8(getAttribute(tag, 'alt') or '')
        return ('<img src="%s" alt="%s"/>'):format(href, escape(alt))
    end)

    local cover
    if opts.fetch_cover then
        local content, content_type = opts.fetch_cover()
        local ext = content and EpubBuilder.detectImageExtension(content, content_type)
        if ext and ext ~= 'svg' then
            cover = {
                id = 'cover-image',
                href = 'images/cover.' .. ext,
                mimetype = IMAGE_MIMETYPES[ext],
            }
            zip:add('OEBPS/' .. cover.href, content, true)
        end
    end

    zip:add('OEBPS/content.html', xhtml)
    zip:add('OEBPS/stylesheet.css', STYLESHEET)
    zip:add('OEBPS/toc.ncx', buildTocNcx(opts))
    zip:add('OEBPS/content.opf', buildContentOpf(opts, images, cover))
    zip:close()

    if lfs.attributes(tmp_path, 'mode') ~= 'file' then
        return nil, Error.new('Could not write file: ' .. tmp_path)
    end
    -- Replace any previous download of this bookmark only once the new one is complete
    local renamed, rename_err = os.rename(tmp_path, opts.path)
    if not renamed then
        -- Some filesystems refuse to rename over an existing file
        os.remove(opts.path)
        renamed, rename_err = os.rename(tmp_path, opts.path)
    end
    if not renamed then
        os.remove(tmp_path)
        return nil, Error.new('Could not write file: ' .. tostring(rename_err))
    end

    collectgarbage()
    collectgarbage()
    return true, nil
end

return EpubBuilder
