local _ = require('gettext')

local getServerSettings = require('karakeep/features/menu/settings/server_config')
local updateMenuItems = require('karakeep/features/update/menu_items')
local SyncMenu = require('karakeep/features/sync/sync_menu')
local BrowseMenu = require('karakeep/features/browser/browse_menu')
local getDownloadFolderSetting = require('karakeep/features/menu/settings/download_folder')

---@param karakeep Karakeep
return function(karakeep)
    local menu_items = {
        text = _('Karakeep'),
        sorting_hint = 'tools',
        sub_item_table = {
            BrowseMenu.getBrowseMenuItem(karakeep),
            {
                text = _('Settings'),
                separator = true,
                sub_item_table = {
                    getServerSettings(karakeep),
                    getDownloadFolderSetting(karakeep),
                    updateMenuItems.getUpdateSettingsMenuItem(karakeep),
                },
            },
            SyncMenu.getSyncPendingMenuItem(karakeep),
            updateMenuItems.getCheckForUpdatesMenuItem(karakeep),
        },
    }

    return menu_items
end
