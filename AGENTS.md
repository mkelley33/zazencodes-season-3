# AGENTS.md

## Project Instructions

- `README.md` is the public landing page for this repo and should stay simple.
- Only include top-level folders from `src/` that already have matching published video content in `/Users/alex/pro/zazencodes-content/videos`.
- Do not include unpublished folders in `README.md`.
- Keep the `README.md` video index in reverse chronological order so the newest published videos appear first.
- When asked to "Update the README", assume existing README entries are still correct. Only check new `src/` folders that are not already linked in `README.md`.

## Repo Shape

- `README.md`: public video index for Season 3.
- `src/<folder>`: one top-level folder per video project or companion resource.
- `scripts/`: maintenance scripts, not video content. Never list it in `README.md`. Run the tests with `bash scripts/<name>.test.sh`.
- `CONTEXT.md`: glossary for the terms the scripts use.
- `/Users/alex/pro/zazencodes-content/videos`: local source of truth for published video metadata.

## README Update Workflow

- Read `README.md` and collect the `src/` folders already linked there.
- List top-level folders in `src/` and find any new folders missing from `README.md`.
- For each new folder, search `/Users/alex/pro/zazencodes-content/videos/**/info.json` for a matching `source_code_url` or obvious folder match.
- If there is no corresponding local content entry, skip that folder for now.
- For matched folders, use local metadata as the source of truth:
  - title from `info.json`
  - YouTube URL from `info.json`
  - optional short description from the folder README or local `summary.md`
- Locate and process the video thumbnail:
  - Look for the matching video folder and its `thumbnail/` subfolder on `/Volumes/T7 Shield/01 . YT . Finals` first.
  - If it is not there, look on `/Volumes/Expansion/ROOT/ZazenCodes YouTube/01 . YT . Finals`.
  - Use the first matching thumbnail found. If neither volume has it, tell the user the thumbnail could not be found in the finalized video folders.
  - Resize the full-resolution image directly to 480px width (480x270, 16:9 ratio) and save the result to `assets/thumbnails/<folder-name>.png` (e.g. `sips --resampleWidth 480 <source> --out <destination>`). Keep the original on the source volume unchanged.
  - Embed the clickable thumbnail in the "Watch" column: `[![<title>](assets/thumbnails/<folder-name>.png)](<youtube-url>)`.
- If the match is unclear, run a targeted web or YouTube search to confirm before editing `README.md`.
- Keep the video index in reverse chronological order based on the matching local video folders.
- Do not re-check or rewrite existing video rows unless the user explicitly asks.

## Validation

- Re-read `README.md` after editing and make sure every row links to the correct `src/<folder>`.
- Confirm every README video row corresponds to a real local content entry in `/Users/alex/pro/zazencodes-content/videos`.
- If a folder has no published local content yet, leave it out of the README.
