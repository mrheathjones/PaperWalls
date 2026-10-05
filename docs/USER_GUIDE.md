# PaperWalls — User Guide

PaperWalls keeps your Mac's desktop looking good: browse beautiful
wallpapers, set one in a click, or let the app rotate them for you.

## Browsing and setting a wallpaper

- **Browse** shows everything at once; the pills underneath (All, Favorites,
  collections, macOS, Personal, …) filter it.
- Hover any wallpaper and click **Set** — done. The wallpaper currently on
  your desktop wears an **ACTIVE** badge.
- Click a card to see details (resolution, file size, source).
- Use the **grid buttons** at the top right of a page to switch between
  2, 3, or 4 columns.
- The **search field** in the toolbar filters every page as you type.

## Favorites

Click the **heart** on any wallpaper to favorite it. Favorites appear under
the Favorites pill and in Collections — and they can drive rotation (below).

## Your own wallpapers (Personal)

Open **Personal** in the sidebar and **drop image files anywhere on the
page** (JPEG, PNG, HEIC, TIFF). They're copied into your personal library —
the original files can stay wherever they were. "Reveal in Finder" opens the
library folder.

## Apple's built-in wallpapers (macOS)

The **macOS** page lists the wallpapers that ship with your Mac. Some aren't
stored on the Mac until needed — those appear under **Available to
download** with two buttons: **Download** (adds it to your library) and
**Download & Set** (downloads and makes it your desktop in one go).

## Auto-rotate

In **Settings → Auto-Rotate**:

- Turn on **Rotate wallpaper** and pick how often.
- Choose **Sources** — which collections of wallpapers rotation draws from.
  Selecting **Favorites** narrows the pick to wallpapers you've hearted.
- **Shuffle** picks randomly; off means in-order. **Change on wake** gives
  you a fresh wallpaper every time you open your Mac.
- The sidebar card and the **menu bar icon** show what's coming ("Up next")
  and offer **Next** / **Rotate** buttons. Closing the window keeps
  PaperWalls running in the menu bar.

## Making your own wallpapers (Studio)

Open **Studio** in the sidebar and choose the **Wallpapers** tab. Start
from a ready-made design — Soft Gradient, Company Badge, Help Desk — or
from a blank one. Pick a **Background** (a wallpaper from your library, an
image of your own, a color, or a gradient), **Add Layer** to put text or an
icon on top, and choose the size from the menu above the preview (your
display is the default). **Save to Personal** renders the wallpaper into
your Personal library, where you can set it like any other. Your design
stays under **Your Designs** in Studio for later edits.

**Generated backgrounds.** If AI generation is turned on in **Settings ›
AI Generation**, an **AI Prompt** section appears under Background, whatever
the background currently is. Describe the image, then press the Generate
button for one of the options that's enabled; the result replaces the
background and is shown whole, with a blurred copy filling the rest of the
screen (the **Fit + Blur** treatment, which you can change):

- **Apple On-Device** opens Image Playground; everything runs on your Mac.
- **Local Model** asks an image server you run yourself (Draw Things,
  Automatic1111, and similar); set its address in Settings.
- **External Model** asks a cloud service (Google, OpenAI, or a compatible
  one) with your own API key, which stays in your Keychain.
- **Improve** rewrites your description into a fuller prompt using Claude.

Local and External generate at your wallpaper's shape, so **Fill** shows
everything. Apple's Image Playground always makes a square picture: keep
**Fit + Blur**, or pick **Fill** and use the **Focus** sliders under
Treatment to choose which part of the picture stays on screen.

Nothing is sent anywhere until you press one of those buttons, and the
Settings page says exactly which service each one talks to. On a work
Mac, your organization may turn some or all of these off.

## Screen savers

PaperWalls can also be your screen saver.

**Make one.** Open **Studio** in the sidebar and choose the **ScreenSaver**
tab. Start from a ready-made design — Bouncing Clock, Floating Message,
Minimal Clock, Help Desk Contact — or from a blank one. Then:

- Pick a **Background**: your current desktop picture, a specific wallpaper,
  a rotating set, a color, or a gradient. Blur and dim it if you like.
- **Add Layer** to put a clock, some text, or an icon on top. Select a layer
  to change its font, color, size, position, and how it moves (bounce,
  drift, float, pulse, fade, orbit).
- In a text layer, the **+ Date**, **+ Computer name**, and **+ Company
  name** buttons insert information that stays up to date.
- The preview at the top shows your changes as you make them; **Test
  Fullscreen** shows the real thing (press any key to leave).
- **Save** puts it in your library.

**Use one.** On the **ScreenSavers** page, click **Set Active** on the one
you want. Click a card to preview it; the **…** button offers rename,
duplicate, edit, and delete.

**Give it its own tile (optional).** In a card's **…** menu, turn on **Show
in System Settings**. That screen saver then appears by name under System
Settings → Screen Saver → Other, with its own picture, so you can choose it
there like any other screen saver.

**Turn it on (one time).** Open **System Settings → Screen Saver**, scroll
to **Other**, and choose **PaperWalls**. From then on your Mac shows
whichever screen saver is active in PaperWalls — change it any time without
going back to System Settings.

## Appearance

**Settings → Theme**: Light, Dark, or System (follows your Mac's appearance
automatically).

## On a work Mac?

If your Mac is managed by an organization, some settings may be greyed out
with a *"Managed by your organization"* badge, sources may be preconfigured
(a company wallpaper collection, for example), and in some setups the
wallpaper choice is locked entirely — you'll see a notice when that's the
case. That's your organization's configuration, not a malfunction.

## If something doesn't work

- Wallpaper won't set? Check for a lock notice (work Macs), then try another
  wallpaper.
- A download fails? Check your internet connection and try again.
- Screen saver shows a simple clock instead of yours? Make sure one is marked
  **ACTIVE** on the ScreenSavers page. Shows a plain color? Screen savers
  are turned off in Settings, or by your organization.
- macOS may ask PaperWalls for permission to access a folder (like
  Downloads) — that's a standard privacy prompt; allowing it just lets the
  app recognize wallpapers stored there.

Still stuck? Contact whoever provided the app — on a work Mac that's your
IT help desk; otherwise, open an issue on the project's GitHub page.
