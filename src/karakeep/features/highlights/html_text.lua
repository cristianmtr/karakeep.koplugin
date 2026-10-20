-- **HtmlText** - Finds KOReader highlights in a Karakeep article.
--
-- Karakeep stores a highlight as offsets into the text of the article's
-- reader view: the browser parses the bookmark's HTML into a DOM, and the
-- offsets count UTF-16 code units over all its text nodes, in document order.
-- This module rebuilds that text from the HTML and locates highlighted text
-- in it, ignoring whitespace (KOReader and the HTML source rarely agree on it).
local HtmlText = {}

-- Elements whose content is a single text node, not parsed as HTML
local RAW_TEXT_ELEMENTS = {
    script = true,
    style = true,
    xmp = true,
    iframe = true,
    noembed = true,
    noframes = true,
    noscript = true,
}
-- Elements whose content is a single text node, with entities decoded
local RCDATA_ELEMENTS = { textarea = true, title = true }
-- The HTML parser drops a newline right after these start tags
local DROP_LEADING_NEWLINE = { pre = true, listing = true, textarea = true }

local NAMED_ENTITIES = {
    amp = '&',
    lt = '<',
    gt = '>',
    quot = '"',
    apos = "'",
    nbsp = '\194\160',
    shy = '\194\173',
    copy = '©',
    reg = '®',
    trade = '™',
    hellip = '…',
    mdash = '—',
    ndash = '–',
    lsquo = '‘',
    rsquo = '’',
    sbquo = '‚',
    ldquo = '“',
    rdquo = '”',
    bdquo = '„',
    laquo = '«',
    raquo = '»',
    middot = '·',
    bull = '•',
    deg = '°',
    times = '×',
    divide = '÷',
    euro = '€',
    pound = '£',
    cent = '¢',
    yen = '¥',
    sect = '§',
    para = '¶',
    prime = '′',
    Prime = '″',
    thinsp = '\226\128\137',
    ensp = '\226\128\130',
    emsp = '\226\128\131',
    zwnj = '\226\128\140',
    zwj = '\226\128\141',
}

---Encode a Unicode code point as UTF-8
---@param cp number
---@return string
local function utf8Char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40
        )
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
    )
end

---Decode HTML character references
---@param text string
---@return string
local function decodeEntities(text)
    if not text:find('&', 1, true) then
        return text
    end
    return (
        text:gsub('&(#?)(%w+);', function(hash, name)
            if hash == '' then
                return NAMED_ENTITIES[name] -- nil keeps unknown entities as is
            end
            local cp
            if name:match('^[xX]%x+$') then
                cp = tonumber(name:sub(2), 16)
            elseif name:match('^%d+$') then
                cp = tonumber(name, 10)
            end
            if not cp then
                return nil
            end
            if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
                cp = 0xFFFD
            end
            return utf8Char(cp)
        end)
    )
end

---Find the ">" ending a tag, skipping quoted attribute values
---@param html string
---@param from number Position after "<"
---@return number
local function findTagEnd(html, from)
    local len = #html
    local i = from
    while i <= len do
        local found = html:find('[>=]', i)
        if not found then
            return len
        end
        if html:sub(found, found) == '>' then
            return found
        end
        -- "=": the value may be quoted
        local value_start = html:find('[^%s]', found + 1) or len + 1
        local quote = html:sub(value_start, value_start)
        if quote == '"' or quote == "'" then
            local close = html:find(quote, value_start + 1, true)
            if not close then
                return len
            end
            i = close + 1
        else
            i = value_start
        end
    end
    return len
end

---Find the end tag of a raw text element ("</script>" etc., any case)
---@param lower_html string Lowercased HTML
---@param name string Element name
---@param from number
---@return number|nil position of "<"
local function findEndTag(lower_html, name, from)
    local needle = '</' .. name
    local i = from
    while true do
        local found = lower_html:find(needle, i, true)
        if not found then
            return nil
        end
        local after = lower_html:sub(found + #needle, found + #needle)
        if after == '' or after:match('[%s/>]') then
            return found
        end
        i = found + 1
    end
end

---Get the text of the DOM a browser builds from this HTML: all text nodes
---concatenated in document order (like Karakeep's TreeWalker over SHOW_TEXT)
---@param html string
---@return string
function HtmlText.extract(html)
    html = html:gsub('\r\n?', '\n')
    local lower_html = html:lower()
    local len = #html
    local out = {}
    local pos = 1
    local drop_newline = false

    while pos <= len do
        local lt = html:find('<', pos, true)
        local text_end = lt and lt - 1 or len
        if text_end >= pos then
            local text = html:sub(pos, text_end)
            if drop_newline and text:sub(1, 1) == '\n' then
                text = text:sub(2)
            end
            table.insert(out, decodeEntities(text))
        end
        drop_newline = false
        if not lt then
            break
        end

        local next_char = html:sub(lt + 1, lt + 1)
        if html:sub(lt, lt + 3) == '<!--' then
            local close = html:find('-->', lt + 4, true)
            pos = close and close + 3 or len + 1
        elseif next_char == '!' or next_char == '?' then
            -- Doctype or bogus comment
            local close = html:find('>', lt + 1, true)
            pos = close and close + 1 or len + 1
        elseif next_char:match('[%a/]') then
            local tag_end = findTagEnd(html, lt + 1)
            local is_end_tag, name = html:sub(lt, tag_end):match('^<(/?)(%a[^%s/>]*)')
            pos = tag_end + 1
            if name and is_end_tag == '' then
                name = name:lower()
                if RAW_TEXT_ELEMENTS[name] or RCDATA_ELEMENTS[name] then
                    local end_tag = findEndTag(lower_html, name, pos)
                    local content = html:sub(pos, (end_tag or len + 1) - 1)
                    if DROP_LEADING_NEWLINE[name] and content:sub(1, 1) == '\n' then
                        content = content:sub(2)
                    end
                    if RCDATA_ELEMENTS[name] then
                        content = decodeEntities(content)
                    end
                    table.insert(out, content)
                    pos = end_tag and findTagEnd(html, end_tag + 1) + 1 or len + 1
                elseif DROP_LEADING_NEWLINE[name] then
                    drop_newline = true
                end
            end
        else
            -- A "<" that doesn't start a tag is text
            table.insert(out, '<')
            pos = lt + 1
        end
    end

    return table.concat(out)
end

---Characters ignored when matching: whitespace, soft hyphens and zero-width characters
---@param cp number
---@return boolean
local function isIgnored(cp)
    return cp == 0x20
        or (cp >= 0x09 and cp <= 0x0D)
        or cp == 0xA0
        or cp == 0xAD
        or cp == 0x1680
        or (cp >= 0x2000 and cp <= 0x200D)
        or cp == 0x2028
        or cp == 0x2029
        or cp == 0x202F
        or cp == 0x205F
        or cp == 0x2060
        or cp == 0x3000
        or cp == 0xFEFF
end

---Iterate over the characters of a UTF-8 string
---@param text string
---@param callback fun(char: string, codepoint: number)
local function eachChar(text, callback)
    local i, n = 1, #text
    while i <= n do
        local b = text:byte(i)
        local len, cp
        if b < 0x80 then
            len, cp = 1, b
        elseif b >= 0xF0 then
            len, cp = 4, b % 0x08
        elseif b >= 0xE0 then
            len, cp = 3, b % 0x10
        elseif b >= 0xC0 then
            len, cp = 2, b % 0x20
        else
            len, cp = 1, 0xFFFD -- stray continuation byte
        end
        for j = i + 1, math.min(i + len - 1, n) do
            cp = cp * 0x40 + text:byte(j) % 0x40
        end
        callback(text:sub(i, i + len - 1), cp)
        i = i + len
    end
end

---Remove ignored characters
---@param text string
---@return string
local function compact(text)
    local chars = {}
    eachChar(text, function(char, cp)
        if not isIgnored(cp) then
            table.insert(chars, char)
        end
    end)
    return table.concat(chars)
end

---@class HtmlTextIndex
---@field compact string Article text without ignored characters
---@field starts table<number, number> Byte position in `compact` -> UTF-16 start offset
---@field ends table<number, number> Last byte position of a char in `compact` -> UTF-16 end offset
---@field length number Length of the article text in UTF-16 code units

---Index the article text for locating highlights
---@param text string Text from HtmlText.extract()
---@return HtmlTextIndex
function HtmlText.buildIndex(text)
    local chars, starts, ends = {}, {}, {}
    local offset = 0 -- in UTF-16 code units
    local byte_pos = 1 -- in the compact string
    eachChar(text, function(char, cp)
        local units = cp >= 0x10000 and 2 or 1
        if not isIgnored(cp) then
            table.insert(chars, char)
            starts[byte_pos] = offset
            ends[byte_pos + #char - 1] = offset + units
            byte_pos = byte_pos + #char
        end
        offset = offset + units
    end)
    return { compact = table.concat(chars), starts = starts, ends = ends, length = offset }
end

---Locate highlighted text in the article.
---When the text appears several times, the occurrence closest to
---`position` (0..1, how far into the document the highlight is) wins.
---@param index HtmlTextIndex
---@param text string Highlighted text
---@param position number|nil
---@return number|nil start_offset, number|nil end_offset UTF-16 offsets
function HtmlText.locate(index, text, position)
    local needle = compact(text)
    if needle == '' then
        return nil
    end

    local best_start, best_end, best_distance
    local init = 1
    while true do
        local first, last = index.compact:find(needle, init, true)
        if not first then
            break
        end
        local start_offset, end_offset = index.starts[first], index.ends[last]
        if start_offset and end_offset then
            local distance = position
                    and math.abs(start_offset / math.max(index.length, 1) - position)
                or 0
            if not best_distance or distance < best_distance then
                best_start, best_end, best_distance = start_offset, end_offset, distance
            end
            if not position then
                break
            end
        end
        init = first + 1
    end
    return best_start, best_end
end

return HtmlText
