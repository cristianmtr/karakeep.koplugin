# Karakeep KOReader Plugin

A KOReader plugin to access your Karakeep bookmarks directly on your e-reader.

## Features

This plugin integrates with [Karakeep](https://karakeep.app/), a self-hostable “Bookmark Everything” app that lets you save links, notes and images with ai-generated tags them with AI—and uses Karakeep’s REST API (with HTTP Bearer JWT authentication) for secure data access.

### Bookmarks

- [x] Create Bookmarks
  - [x] Save links
  - [x] Export Highlights 
- [x] Browse your bookmarks (Unarchived, Favourites, Lists)
- [x] Search bookmarks
- [x] Download bookmarks for offline access
- [x] Sync highlights of downloaded articles to Karakeep

## Prerequisites

- KOReader **2025.04** or later
- A running Karakeep instance (v0.25.0+)
- An API key generated in Karakeep under **User Settings > API Keys**

## Installation

1. Download latest release from the [Releases](https://github.com/cristianmtr/karakeep.koplugin/releases) page.
2. Extract the `karakeep.koplugin` folder into your KOReader `plugins/` directory.
3. Restart KOReader.
4. Enable **Karakeep** under **Settings > Plugins**.

## Configuration

1. In KOReader, go to **Tools > Karakeep**.
2. Set the **Server address** (e.g. `https://karakeep.example.com`).
3. Enter your **API token**.
4. Save and exit.

## Usage

### Browsing and downloading bookmarks

Go to **Tools > Karakeep > Browse bookmarks** and pick a view:

- **Unarchived**: everything not archived, newest first
- **Favourites**: starred bookmarks
- **Lists**: pick one of your Karakeep lists
- **Search**: full-text search with Karakeep's search syntax

Bookmarks are listed by title, 10 per page. Moving past the last loaded page fetches the next 10 from Karakeep.

Tap a title to **Download** it or **Download & open** it. Already-downloaded bookmarks offer **Open** and **Download again**; downloading again overwrites the same file, so your reading position is kept.

What gets downloaded:

- Articles (links) and notes become an **EPUB** with their images embedded, readable offline.
- PDFs and images are saved as the original file.

Files are saved to `<home folder>/Karakeep` by default. Change this under **Tools > Karakeep > Settings > Download folder**.

### Syncing highlights to Karakeep

Highlights you make in an article downloaded from Karakeep show up on that bookmark in Karakeep, in its reader view and highlights list.

- Highlights are sent a few seconds after you create, edit or delete them. Deleting a highlight in KOReader deletes it in Karakeep, and changing its note or color updates it there. Only highlights created by the plugin are touched.
- If you're offline, changes wait and are sent when Wi-Fi connects, when you reopen or close the article, or when you sync manually.
- To sync manually, use **Tools > Karakeep > Sync highlights to Karakeep**. In the reader it syncs the open article; in the file browser it syncs all downloaded articles.
- Karakeep has four colors, so KOReader colors map to the closest one: orange → red, olive → green, cyan and purple → blue, gray → yellow.
- Karakeep only supports highlights on web articles (link bookmarks), not on notes, PDFs or images.
- A highlight is located by its text in the article. If the article changed in Karakeep since you downloaded it, or you highlight the title heading the plugin adds at the top, it can't be found and isn't synced; the plugin tells you when that happens.

### Bookmarking links

A new **"Save to Karakeep"** option will appear in the links dialog action when clicking a link.

- If there is a network or server issue, the plugin will queue the item locally and sync it as soon as connectivity is restored, or when you manually trigger a sync.
