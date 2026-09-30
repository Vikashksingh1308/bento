# 🍱 Bento

**A delightful macOS window manager that keeps your desktop tidy.**

Snap, resize, and organize your windows effortlessly with keyboard shortcuts and drag gestures. Just like a bento box, everything has its perfect place.

---

## ✨ Features

- 🎹 **19 Keyboard Shortcuts** : Instantly snap windows to halves, quarters, thirds, or maximize with a single keystroke
- 🖱️ **Drag-to-Snap** : Just drag any window to a screen edge or corner and watch it snap into place
- ⚙️ **Fully Customizable** : Not a fan of the defaults? Remap every shortcut in Settings to match your workflow
- 🎯 **Menu Bar Native** : Lives quietly in your menu bar, always ready, never in the way
- 🖥️ **Multi-Monitor Ready** : Fling windows across displays with a single shortcut

---

## ⌨️ Default Keyboard Shortcuts

### Halves
| Action | Shortcut |
|--------|----------|
| Left Half | ⌃⌥← |
| Right Half | ⌃⌥→ |
| Top Half | ⌃⌥↑ |
| Bottom Half | ⌃⌥↓ |

### Quarters
| Action | Shortcut |
|--------|----------|
| Top Left | ⌃⌥U |
| Top Right | ⌃⌥I |
| Bottom Left | ⌃⌥J |
| Bottom Right | ⌃⌥K |

### Thirds
| Action | Shortcut |
|--------|----------|
| Left Third | ⌃⌥D |
| Center Third | ⌃⌥F |
| Right Third | ⌃⌥G |
| Left Two Thirds | ⌃⌥E |
| Center Two Thirds | ⌃⌥R |
| Right Two Thirds | ⌃⌥T |

### Sizing & Positioning
| Action | Shortcut |
|--------|----------|
| Maximize | ⌃⌥↩ |
| Center | ⌃⌥C |
| Restore | ⌃⌥⌫ |

### Multi-Display
| Action | Shortcut |
|--------|----------|
| Next Display | ⌃⌥⌘→ |
| Previous Display | ⌃⌥⌘← |

> 💡 Don't like these? Every shortcut can be remapped in **Bento → Settings → Shortcuts**.

---

## 📋 Requirements

- macOS 12 (Monterey) or later
- Xcode 15+ (only if building from source)

---

## 🚀 Installation

### Quick Install
1. Download the latest **Bento.dmg** from [Releases](../../releases)
2. Open the DMG and drag **Bento** to your Applications folder
3. Launch Bento — you'll find it in your menu bar 🎉

> **First launch:** Right-click **Bento.app** → **Open** to bypass macOS Gatekeeper (only needed once).

### Grant Permissions
On first launch, Bento will ask for **Accessibility** access. This is required to move and resize windows.

**System Settings → Privacy & Security → Accessibility → ✓ Bento**

---

## 🛠️ Build from Source

Want to tinker with the code? Easy:

​```bash
git clone https://github.com/yourusername/bento.git
cd bento
open Bento.xcodeproj
​```

Then press **⌘R** in Xcode to build and run.
