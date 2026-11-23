# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.03] - 2026-11-23
### Changed
- A new install starts with no music folders (it used to fill in Windows' Music folder) and no media server
  address (it used to fill in http://localhost); add your own in **Sources...**. The usual address is a tooltip.

## [1.02] - 2026-11-23
### Changed
- The names of the folders inside the picture folders (**Album Pictures**, **Artist Pics**, **Movies** and **TV**)
  are settings in **Sources...**, so they can match your own. The names stay the same unless you change them.
- Neutral wording: "Not saved in the picture folder" instead of naming a folder, and plainer Help and README.

## [1.01] - 2026-11-22

### Added
- **Remove folder...** beside Add folder...: pick a folder from the menu to take it off the list.
  The folder and its files stay where they are.

### Fixed
- Help and the README show `Artist Pics\<Artist>\folder.jpg` properly (the "\f" was lost).

## [1.00] - 2026-11-21
First release.

### Added
- **Music check** of your music folders: each album's `cover.jpg` and its copy in
  `<picture folder>\Album Pictures\<Artist>\<Artist> - <Album>.jpg` (missing, unreadable or not exactly
  500 x 500), and each artist's `folder.jpg` in `<picture folder>\Artist Pics\<Artist>` and `artist.jpg`
  in its folder (missing; any size). Albums without a cover file whose tracks carry their own
  cover are marked as worth a look. CD1 / Disc 2 folders count as one album.
- **Films and TV check** in Jellyfin, Plex or Emby: every film, show and season's poster (missing, narrower than
  600 pixels or not poster-shaped), whether films and shows have a background, and whether the
  poster is saved in the picture folder's `Movies` or `TV` folder. **Save posters** copies the missing
  ones from the server.
- Music, Films and TV tabs with counts, red / amber / green problems, Problems only, search, a
  picture preview, Open folder or Open in the server, Export (the list as CSV, or the pictures as
  files in a folder you choose: album covers and artist pictures laid out like Album Pictures and
  Artist Pics, or every poster and background from the server), and the last scan kept for the
  next start. Scans run in the background and can be stopped.
- **Sources...** says where everything comes from: music from this PC or the
  NAS, each with its own folders, and the music picture folder; and
  the media server for films and TV (Jellyfin, Plex or Emby, with its address and key, and a Test
  button) and its picture folder, plus the cover size and smallest poster width. Save keeps the
  window open; Close closes it. Kept in
  %APPDATA%\Artwork Checker.
- Light, Dark and Auto looks, Help and an About box. Listed in the Home Launcher's Media tab.
