local _ = require('gettext')

-- **Error** - Simple error handling utility that provides consistent error
-- objects. Focuses on what we actually need: standardized error objects with
-- message property.
---@class Error # Error object with message property
---@field message string
---@field status? number HTTP status code, when the error comes from an HTTP response
local Error = {}

---Create a new error object
---@param message string Human-readable error message
---@param status? number HTTP status code
---@return Error # Error object with message property
function Error.new(message, status)
    return {
        message = message or _('Unknown error occurred'),
        status = status,
    }
end

return Error
