# Studio › Wallpapers — generation plan

Status: all four phases landed (October 2026).

PaperWalls already has everything needed to *compose* a wallpaper: the
scene model (`ScreenSaverScene`), the Scene Composer UI, the frame
renderer (`SceneFrameView`), and an `ImageRenderer` snapshot path. A
wallpaper is one frame of a scene, rendered at a display's pixel size and
written into the user's Personal library. AI generation is an extra way
to obtain the *background* of that scene — nothing else changes.

## Goals

1. Studio › Wallpapers mirrors Studio › ScreenSaver: start blank or from a
   preset, compose a background (image, color, gradient) plus text and
   icon layers, save.
2. Saving renders a PNG at a chosen pixel size into the Personal library,
   where it behaves like any other wallpaper (Set, favorite, rotate,
   package for deployment).
3. Optional AI backgrounds, behind a master toggle and one sub-toggle per
   provider: **Apple On-Device**, **Local Model**, **External Model**.
   Every toggle is a managed preference so admins can lock it off.
4. Nothing in AI generation is required for the feature to work; with all
   AI toggles off the tab is a plain composer.

## Phase 1 — Composer-based wallpapers (this branch)

### Model

* New background source `image(assetName:)` (JSON `kind: "image"`): a
  picture imported into the Studio asset store, the same store icon
  images use. It renders in the app and the saver, ships inside deployed
  saver bundles, and gives screen savers an "import an image" background
  as a side benefit. Older app versions keep it as `unsupported` (black),
  per the scene format's forward-compatibility rule. No schema bump.
* `StoredWallpaperDesign` in `Shared/WallpaperDesignStore.swift`:
  `id`, `name`, `createdAt`, `modifiedAt`, `scene`, `pixelWidth`,
  `pixelHeight`, `exportedFilename`. One JSON per design in
  `~/Library/Application Support/PaperWalls/Studio/Wallpapers/`, with
  `Thumbnails/<id>.png`, following `ScreenSaverSceneStore` exactly
  (atomic writes, lenient decode, corrupt files skipped).
* `WallpaperPreset` (`Shared/WallpaperPresets.swift`): Blank, Gradient,
  Company Badge, Help Desk. Read-only templates.

### Rendering

* `ScreenSaverThumbnailer.render` gains `size`/`scale`/`maxBackgroundPixels`
  parameters; `WallpaperRenderer` (App) calls it at the target pixel size
  (points = pixels / 2, scale 2) with background images decoded at full
  target resolution.
* Output sizes offered: each connected display's pixel size (main first,
  default), then 5120×2880, 3840×2160, 2560×1600, 2560×1440, 1920×1080.
  The chosen size is saved with the design so a re-save renders the same.
* Layers render at `time: 0` with motion ignored; the composer hides the
  Motion section in wallpaper mode.

### UI

* `StudioWallpapersTab` (new file): "New Wallpaper" template grid and a
  "Your Designs" grid (Edit, Rename, Set as Wallpaper, Reveal Image,
  Delete). A design in progress opens the Scene Composer.
* `SceneComposer` gains `kind: .screenSaver | .wallpaper` (an environment
  value for the control views). Wallpaper mode: no Clock layer, no Motion,
  no Current Desktop / Rotating backgrounds, no Slow zoom; a Size menu in
  the toolbar; preview aspect follows the chosen size; Save renders and
  writes to the Personal folder, then offers "Set as Wallpaper".
* Save destination is `effectivePersonalFolderPath` (app-managed folder by
  default, the user's own folder if configured). A re-save overwrites the
  design's previous PNG so the library doesn't fill with versions.
* Gate: the existing `showStudioWallpapersTab` key. Settings subtitle and
  the README / Admin Guide key tables lose their "coming soon" wording.

### Tests

* Design store round trip, delete, unique naming, corrupt file skipped.
* `image` background codec round trip; unknown kinds still preserved.
* Export filename sanitization; render-size option list.
* Existing Studio tab visibility tests unchanged.

## Phase 2 — Apple On-Device (landed)

Landed as `Shared/AIGenerationPolicy.swift` (pure gating + tests), the four
managed keys below, a Settings › AI Generation card, and
the generator rows under Background › An Image in the composer. The
Apple path needs no provider protocol, since the system sheet owns the
whole flow.

```swift
protocol WallpaperImageProvider {
    var id: String { get }          // "apple", "local", "external"
    var displayName: String { get }
    var isAvailable: Bool { get }   // Apple Intelligence on, endpoint reachable…
    func generate(_ request: GenerationRequest) async throws -> [GeneratedImage]
}
struct GenerationRequest { var prompt: String; var style: String?; var count: Int; var referenceImage: CGImage? }
struct GeneratedImage { var image: CGImage; var providerID: String; var prompt: String }
```

A generated image is imported into the Studio asset store and becomes an
`image(assetName:)` background. Fill / blur / dim then handle the aspect
ratio, because every provider returns roughly square ~1K images, not 5K.

**Apple On-Device.** Framework `ImagePlayground` (macOS 15.4+; the App
target is macOS 26). Primary path: the `imagePlaygroundSheet` SwiftUI
modifier (`isPresented:`, `concepts:`, `sourceImage:`, `onCompletion:`
giving a file URL). It is Apple's own UI and is **not** deprecated.
`ImageCreator` (programmatic `images(for:style:limit:)`) exists but Apple
marks it deprecated in macOS 27, so it is not the default path; it can be
offered as an "in-place generate" option behind the same toggle if Heath
wants batch generation. Availability: `@Environment(\.supportsImagePlayground)`.
Requires Apple Silicon and Apple Intelligence enabled; MDM can disable
Image Playground, so the tile shows an explanatory disabled state.
Styles are Apple's (`illustration`, `animation`, `sketch`, `any`, …).

Preference keys (all managed-aware, default `false`):

| Key | Meaning |
|---|---|
| `aiGenerationEnabled` | Master switch. Off hides every AI control. |
| `aiAppleOnDeviceEnabled` | Apple On-Device sub-toggle. |
| `aiLocalModelEnabled` | Local Model sub-toggle. |
| `aiExternalModelEnabled` | External Model sub-toggle. |

Settings › "AI Generation" card: master toggle, then the three rows
disabled while the master is off, each with its own settings beneath.

## Phase 3 — Local Model (landed)

Landed as `Shared/LocalImageEndpoint.swift` (pure request building and
reply parsing for both API dialects, with tests), `App/LocalImageProvider.swift`
(the `WallpaperImageProvider` protocol, the URLSession provider, and a
Keychain helper for an optional bearer token), the four endpoint keys
below, Settings rows (endpoint, API, model, size, key, Test Connection),
and a Local Model button in the composer's generator rows.

No bundled CoreML Stable Diffusion (gigabytes of weights, and the project
has no SPM). "Local" means a local HTTP endpoint the user already runs:
Draw Things, ComfyUI, Automatic1111 (`/sdapi/v1/txt2img`), or any
OpenAI-compatible `/v1/images/generations`. Settings: base URL, API
flavor picker, model name, optional size. An optional bearer token goes to the
Keychain. Managed keys: `aiLocalModelEndpoint`, `aiLocalModelFlavor`,
`aiLocalModelName`, `aiLocalModelImageSize` (admin can pre-fill; user can
edit unless forced). ComfyUI's workflow-graph API is not covered; run it
behind an Automatic1111-compatible shim or use Draw Things.

## Phase 4 — External Model (landed)

Landed as `Shared/ExternalImageEndpoint.swift` (Google Gemini image models,
OpenAI `gpt-image-1`, OpenAI-compatible; shapes mapped per service; shared
`ImageAPIReply` parsers), `Shared/PromptImprover.swift` (Anthropic Messages
API request/reply for Improve, `claude-opus-5-5` by default with
`fallbacks: "default"` and low effort), `App/ExternalImageProvider.swift`,
the keys below, Settings rows (service, endpoint, model, shape, per-service
Keychain key, Test Connection; Claude model + key), and External Model /
Improve controls in the composer. Admin-supplied keys were deliberately
not added: admins pre-fill the service and model, users enter their own
key.

Provider picker under the toggle: **Google** (Gemini image models, the
"Nano Banana" family), **OpenAI** (`gpt-image-1`), **OpenAI-compatible**
(any URL). Claude is not an image generator; an optional "Improve prompt
with Claude" step can rewrite a short brief into a proper image prompt,
behind its own key, but is separate from pixel generation.

API keys are stored in the login Keychain under the app's service name
(never in the preference domain, which is deployed as managed plists and
would leak keys into profiles). Managed keys: `aiExternalProvider`,
`aiExternalEndpoint`, `aiExternalModelName`. Network use is explicit:
nothing is sent until the user presses Generate, and the Settings copy
says which host receives the prompt.

## Open questions for Heath

* Should a renamed design also rename its exported PNG? (Phase 1 keeps the
  original filename so favorites and rotation pools keep working.)
* Batch generation with `ImageCreator` despite its deprecation, or sheet
  only?
* Should admins be able to supply External Model keys through managed
  preferences for fleet use? Convenient, but it puts a secret in a profile.

## Phase 6 — Compose screen savers with Claude (October 2026)

Extends AI generation from backgrounds to whole scenes. A new
`aiSceneComposerEnabled` sub-toggle (same master switch, same Claude key
and `aiPromptImproverModel` model) adds a **Compose with Claude** card to
Studio › ScreenSaver. `Shared/SceneGenerator.swift` builds the Anthropic
Messages request with a JSON-outputs schema (`output_config.format`,
`type: json_schema`) describing a friendlier `SceneComposition` shape —
background kind + colors/treatment, flat layers with placeholders
(`{date}`, `{computerName}`, `{companyName}`) — and the system prompt
explains the relative-coordinate canvas, sizes, motions and legibility
rules. `SceneComposition.scene(symbolExists:)` applies the format rules
before anything becomes a `ScreenSaverScene`: values clamped, hex
normalized or replaced, unknown SF Symbols → `sparkles`, at most 8 layers,
and only backgrounds Claude can legitimately pick (no library wallpaper
IDs or asset names). A `generatedImage` background is offered only when a
Local or External image provider is on, configured and keyed; Claude then
writes `imagePrompt`, the app generates the picture with that provider
(`App/AISceneComposer.swift`), imports it into the asset store and sets
Fit + Blur. If the picture fails, the user can open the scene with Claude's
stand-in gradient instead. The result is a normal unsaved `SceneDraft`.
