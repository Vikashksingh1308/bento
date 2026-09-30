#!/bin/bash

# Build settings
APP_NAME="Bento"
BUILD_DIR="build"
RELEASE_DIR="$BUILD_DIR/Release"
APP_PATH="$RELEASE_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME.dmg"
DMG_TEMP="$BUILD_DIR/dmg-temp"
DMG_FINAL="$BUILD_DIR/$DMG_NAME"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Building Bento DMG...${NC}"

# Step 1: Build the app in Release mode
echo -e "${YELLOW}Step 1: Building app in Release mode...${NC}"
xcodebuild -scheme Bento -configuration Release -derivedDataPath "$BUILD_DIR" CONFIGURATION_BUILD_DIR="$RELEASE_DIR"

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Error: App build failed. $APP_PATH not found.${NC}"
    exit 1
fi

echo -e "${GREEN}✓ App built successfully${NC}"

# Step 2: Create temporary DMG directory structure
echo -e "${YELLOW}Step 2: Creating DMG structure...${NC}"
rm -rf "$DMG_TEMP"
mkdir -p "$DMG_TEMP"

# Copy app to DMG temp directory
cp -r "$APP_PATH" "$DMG_TEMP/"

# Create Applications symlink
ln -s /Applications "$DMG_TEMP/Applications"

# Create .DS_Store with custom appearance (optional - requires AppleScript)
# For now, we'll skip the fancy appearance

echo -e "${GREEN}✓ DMG structure created${NC}"

# Step 3: Create the DMG
echo -e "${YELLOW}Step 3: Creating DMG file...${NC}"
rm -f "$DMG_FINAL"

hdiutil create -volname "$APP_NAME" \
               -srcfolder "$DMG_TEMP" \
               -ov -format UDZO \
               "$DMG_FINAL"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ DMG created successfully: $DMG_FINAL${NC}"
else
    echo -e "${RED}Error: Failed to create DMG${NC}"
    exit 1
fi

# Step 4: Cleanup
echo -e "${YELLOW}Step 4: Cleaning up...${NC}"
rm -rf "$DMG_TEMP"

# Calculate size
SIZE=$(du -sh "$DMG_FINAL" | cut -f1)
echo -e "${GREEN}✓ Done! DMG size: $SIZE${NC}"
echo -e "${GREEN}DMG file: $DMG_FINAL${NC}"
