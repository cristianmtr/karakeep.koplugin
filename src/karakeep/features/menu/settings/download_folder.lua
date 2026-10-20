local _ = require('gettext')
local filemanagerutil = require('apps/filemanager/filemanagerutil')
local T = require('ffi/util').template

local DownloadService = require('karakeep/features/download/download_service')

---@param karakeep Karakeep
return function(karakeep)
    return {
        text_func = function()
            return T(
                _('Download folder: %1'),
                filemanagerutil.abbreviate(karakeep.ui.karakeep_downloader:getDownloadDir())
            )
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local default_dir = DownloadService.getDefaultDownloadDir()
            filemanagerutil.showChooseDialog(_('Folder for downloaded bookmarks:'), function(path)
                -- Store an empty value for the default so it follows the home folder
                karakeep.settings.download_dir = path ~= default_dir and path or ''
                touchmenu_instance:updateItems()
            end, karakeep.ui.karakeep_downloader:getDownloadDir(), default_dir)
        end,
    }
end
