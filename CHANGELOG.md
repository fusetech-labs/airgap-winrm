# Changelog

All notable changes to this project are recorded here. The format follows Keep a Changelog
(https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- The repository moved from `ChrisFryer/Offline-Updates` to `fusetech-labs/airgap-winrm`, and the product is now
  the Airgap WinRM Toolkit, published by Fusetech (https://fusetech.com.au). The source link in the About tab and
  the README point at the new repository.
- The toolkit is licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE and COMMERCIAL.md). Every
  published script now carries a licence header (Copyright Fusetech, SPDX-License-Identifier
  PolyForm-Noncommercial-1.0.0); the scripts need re-signing.
- Internal names are unchanged so existing deployments keep working: the `\WinRMToolkit\` task folder, the
  `OfflinePatcher` event source, `Start-WinRMToolkit.ps1`, the settings keys and the file layout.
- The window title ends "offline, over WinRM" instead of naming the port.
- Health grid: the Light column is gone (the row colour already says it), and every cell that stands for a check
  carries that check's own colour, so a green or amber cell shows inside a row that is red for another finding.
- SOE standards, Add by hand: the item form shows only the boxes the chosen type uses, offers a list wherever a
  value must match exactly (type, agents, setting keys, start types, states), fills a registry or file rule from the
  known configuration points, keeps what was typed when something is missing, and has a Help button.
- Support and licensing enquiries go to products@fusetech.com.au; the About tab shows it and the Fusetech website.

### Added

- LICENSE (PolyForm Noncommercial 1.0.0 with the required notice), COMMERCIAL.md (when a commercial licence is
  needed) and SECURITY.md (how to report a vulnerability).
- A trademark note at the foot of the README.
- The Fusetech look: a frame in the brand blue round the window, a window icon drawn at start-up (the logo's
  bolt on a blue square, no picture file to ship) and the same icon as the favicon of every HTML page.
