// Plug-in editors for isolated instances (ADR-0015): the editor lives in a window owned by dalnok-plughost.
// The host becomes an accessory AppKit application the first time an editor opens; the window is a non-activating
// floating panel, so Dalnok stays the active application (menu bar, shortcuts) while the editor still takes clicks
// and typing. It follows Dalnok: hidden while another application is active, shown again when Dalnok is.
// SPDX-License-Identifier: GPL-3.0-or-later
#include "plughost_editor.hpp"
#include "../../plugin_host.hpp"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <cmath>
#include <unistd.h>

using dalnok::PluginProcessor;

@interface DalnokEditorPanel : NSPanel
@end
namespace dalnok::hostui { void forwardKey(NSEvent *event); }

@implementation DalnokEditorPanel
- (BOOL)canBecomeKeyWindow { return YES; } // typing reaches the editor without activating the host
// The panel has the keyboard while Dalnok stays active, so keys the editor does not use (Space, ⌘S, ⌘Z outside a text
// field) are passed back to Dalnok instead of being lost.
- (void)keyDown:(NSEvent *)event { dalnok::hostui::forwardKey(event); } // nothing in the editor took it
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ([super performKeyEquivalent:event]) return YES; // the editor's own views
    // Standard text editing (⌘A, ⌘C, ⌘V, ⌘X, ⌘Z) through the hidden Edit menu, only while a text field is being edited.
    if ([self.firstResponder isKindOfClass:NSText.class] && [NSApp.mainMenu performKeyEquivalent:event]) return YES;
    dalnok::hostui::forwardKey(event);
    return YES;
}
@end

@interface DalnokEditorController : NSObject <NSWindowDelegate>
@property(nonatomic, strong) DalnokEditorPanel *panel;
@property(nonatomic) PluginProcessor *plugin;
@property(nonatomic) BOOL wanted;        // the user has it open (it may be hidden while Dalnok is in the background)
@end

namespace dalnok::hostui { void fitEditor(); void requestControls(); }

@implementation DalnokEditorController
// The title bar's Controls button: Dalnok shows the plug-in's controls (its parameter view) instead.
- (void)showControls:(id)sender {
    (void)sender;
    dalnok::hostui::requestControls();
}
- (void)editorFrameChanged:(NSNotification *)note {
    (void)note;
    dalnok::hostui::fitEditor();
}
- (void)windowWillClose:(NSNotification *)note {
    (void)note;
    self.wanted = NO;
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSViewFrameDidChangeNotification object:nil];
    if (self.plugin) self.plugin->closeEditor();
}
// The host must never be the active application (Dalnok keeps its menu bar and shortcuts). If the system hands it
// activation anyway (launch activation arrives asynchronously), give it straight back.
- (void)hostBecameActive:(NSNotification *)note {
    (void)note;
    NSRunningApplication *parent = [NSRunningApplication runningApplicationWithProcessIdentifier:getppid()];
    if (!parent) return;
    if (@available(macOS 14.0, *)) [NSApp yieldActivationToApplication:parent];
    [parent activateWithOptions:0];
}
- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!self.panel || !self.wanted || !app) return;
    if (app.processIdentifier == getppid()) [self.panel orderFront:nil];
    else if (app.processIdentifier != getpid()) [self.panel orderOut:nil];
}
@end

namespace dalnok::hostui {
namespace {
DalnokEditorController *gEditor = nil;
bool gAppReady = false;
KeySink gKeySink = nullptr;

// Resizable editors (autoresizing in both directions, as Audio Unit views are) fill a resizable window; fixed-size ones
// set the window's size.
// A panel that grew (the editor resized itself after opening) is moved back inside its screen's visible area.
NSRect onScreen(NSRect frame) {
    NSScreen *screen = gEditor.panel.screen ?: NSScreen.mainScreen;
    if (!screen) return frame;
    const NSRect vf = screen.visibleFrame;
    if (NSMaxX(frame) > NSMaxX(vf)) frame.origin.x = std::max(NSMinX(vf), NSMaxX(vf) - frame.size.width);
    if (frame.origin.x < NSMinX(vf)) frame.origin.x = NSMinX(vf);
    if (NSMaxY(frame) > NSMaxY(vf)) frame.origin.y = NSMaxY(vf) - frame.size.height;
    if (frame.origin.y < NSMinY(vf)) frame.origin.y = std::min(NSMinY(vf), NSMaxY(vf) - frame.size.height);
    return frame;
}

// fit() resizes the window, which lays the editor out again, and an editor whose layout then changes its own frame
// posts a frame change that calls fit() again from inside the first call. AUSampler's view recursed like that until
// AppKit aborted ("_enumeratingSubviewsCount" overflow). A change that arrives while fitting is handled once, on the next
// turn of the run loop, and a view that keeps changing size after kMaxFitPasses resizes in quick succession (each within
// half a second of the last) keeps its window until it settles.
bool gFitting = false, gFitQueued = false;
int gFitPasses = 0;
double gLastFitResize = 0;
constexpr int kMaxFitPasses = 8;

bool fitOnce();
void fit() {
    if (gFitting) {
        if (!gFitQueued) {
            gFitQueued = true;
            dispatch_async(dispatch_get_main_queue(), ^{ gFitQueued = false; fit(); });
        }
        return;
    }
    const double now = NSProcessInfo.processInfo.systemUptime;
    if (now - gLastFitResize > 0.5) gFitPasses = 0;
    if (gFitPasses >= kMaxFitPasses) return;
    gFitting = true;
    const bool resizedWindow = fitOnce();
    gFitting = false;
    if (resizedWindow) { ++gFitPasses; gLastFitResize = now; }
    else gFitPasses = 0;
}

// Returns true when it changed the window's frame.
bool fitOnce() {
    NSView *view = gEditor.panel.contentView.subviews.firstObject;
    if (!view) return false;
    bool changed = false;
    const bool flexible = (view.autoresizingMask & NSViewWidthSizable) && (view.autoresizingMask & NSViewHeightSizable);
    if (flexible) {
        gEditor.panel.styleMask |= NSWindowStyleMaskResizable;
        if (!NSEqualRects(view.frame, gEditor.panel.contentView.bounds)) view.frame = gEditor.panel.contentView.bounds;
    } else {
        gEditor.panel.styleMask &= ~NSWindowStyleMaskResizable;
        const NSSize size = view.frame.size;
        if (size.width > 0 && size.height > 0 && !NSEqualSizes(size, gEditor.panel.contentView.bounds.size)) {
            NSRect frame = gEditor.panel.frame;
            const NSRect next = [gEditor.panel frameRectForContentRect:NSMakeRect(0, 0, size.width, size.height)];
            frame.origin.y += frame.size.height - next.size.height; // keep the top edge
            frame.size = next.size;
            [gEditor.panel setFrame:onScreen(frame) display:YES];
            // A view that autoresizes in one direction only (AUSampler: width) was resized along with the window by the
            // old mismatch, so every pass made it larger again. It keeps the size it asked for.
            if (!NSEqualSizes(view.frame.size, size)) [view setFrameSize:size];
            changed = true;
        }
        if (!NSEqualPoints(view.frame.origin, NSZeroPoint)) view.frameOrigin = NSZeroPoint;
    }
    return changed;
}

void resized(void *, int32_t w, int32_t h) {
    if (!gEditor.panel || w <= 0 || h <= 0) return;
    NSRect frame = gEditor.panel.frame;
    const NSRect next = [gEditor.panel frameRectForContentRect:NSMakeRect(0, 0, w, h)];
    frame.origin.y += frame.size.height - next.size.height; // keep the top edge
    frame.size = next.size;
    [gEditor.panel setFrame:onScreen(frame) display:YES];
}
} // namespace

bool appStarted() { return gAppReady; }
void fitEditor() { fit(); }

void startApp() {
    if (gAppReady) return;
    [NSApplication sharedApplication];
    // A GUI process started by the active application is normally handed activation when it finishes launching; the
    // host must never take it from Dalnok. Finish launching while activation is prohibited, then become an accessory
    // application (no Dock icon or menu bar) whose non-activating panels can still take clicks and typing.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    [NSApp finishLaunching];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // No menu bar is shown, but text fields in editors still need the standard key equivalents (⌘A, ⌘C, ⌘V, ⌘Z),
    // which AppKit routes through the main menu.
    NSMenu *main = [NSMenu new], *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    NSMenuItem *editItem = [NSMenuItem new];
    editItem.submenu = edit;
    [main addItem:editItem];
    const struct { NSString *title; SEL action; NSString *key; NSEventModifierFlags mods; } items[] = {
        {@"Undo", NSSelectorFromString(@"undo:"), @"z", NSEventModifierFlagCommand},
        {@"Redo", NSSelectorFromString(@"redo:"), @"z", NSEventModifierFlagCommand | NSEventModifierFlagShift},
        {@"Cut", @selector(cut:), @"x", NSEventModifierFlagCommand},
        {@"Copy", @selector(copy:), @"c", NSEventModifierFlagCommand},
        {@"Paste", @selector(paste:), @"v", NSEventModifierFlagCommand},
        {@"Select All", @selector(selectAll:), @"a", NSEventModifierFlagCommand},
    };
    for (const auto &i : items) {
        NSMenuItem *m = [[NSMenuItem alloc] initWithTitle:i.title action:i.action keyEquivalent:i.key];
        m.keyEquivalentModifierMask = i.mods;
        [edit addItem:m];
    }
    NSApp.mainMenu = main;
    gAppReady = true;
}

void runApp() { [NSApp run]; }

void setKeySink(KeySink sink) { gKeySink = sink; }

// Sent through the key ring as DALNOK_EDITOR_SHOW_CONTROLS (not a key code any keyboard produces).
void requestControls() {
    if (gKeySink) gKeySink(0xFFFF, 0, "", "");
}

void forwardKey(NSEvent *event) {
    if (!gKeySink || (event.type != NSEventTypeKeyDown)) return;
    gKeySink(event.keyCode, event.modifierFlags, event.characters.UTF8String ?: "", event.charactersIgnoringModifiers.UTF8String ?: "");
}

bool showEditor(PluginProcessor &plugin, const std::string &title, double x, double y, int32_t &width, int32_t &height,
                std::string &err) {
    startApp();
    if (!gEditor) {
        gEditor = [DalnokEditorController new];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:gEditor selector:@selector(appActivated:)
                                                               name:NSWorkspaceDidActivateApplicationNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:gEditor selector:@selector(hostBecameActive:)
                                                   name:NSApplicationDidBecomeActiveNotification object:nil];
    }
    if (!gEditor.panel) {
        DalnokEditorPanel *panel = [[DalnokEditorPanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 400, 300)
                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                                NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered defer:NO];
        panel.releasedWhenClosed = NO;
        panel.hidesOnDeactivate = NO; // the host is never the active application
        panel.floatingPanel = YES;    // above Dalnok's windows, which belong to another process
        panel.becomesKeyOnlyIfNeeded = NO;
        // Dalnok's windows can be on another Space (or full screen) than the one the host first drew on, and ordering
        // a window front never moves it between Spaces: it stayed "visible" but off screen. Join every Space instead;
        // appActivated: already hides it whenever Dalnok is not the active application.
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary;
        panel.delegate = gEditor;
        panel.contentView.wantsLayer = YES;
        // Title bar: Controls shows Dalnok's view of the plug-in's parameters (the unit's controller and every
        // parameter), so the plug-in's own window is the only one its unit opens.
        NSButton *controls = [NSButton buttonWithTitle:@"Controls" target:gEditor action:@selector(showControls:)];
        controls.bezelStyle = NSBezelStyleRecessed;
        controls.controlSize = NSControlSizeSmall;
        controls.toolTip = @"Show the plug-in's controls in Dalnok (every parameter, searchable, automatable)";
        NSView *holder = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 86, 24)];
        controls.frame = NSMakeRect(4, 2, 78, 20);
        [holder addSubview:controls];
        NSTitlebarAccessoryViewController *accessory = [NSTitlebarAccessoryViewController new];
        accessory.view = holder;
        accessory.layoutAttribute = NSLayoutAttributeTrailing;
        [panel addTitlebarAccessoryViewController:accessory];
        gEditor.panel = panel;
        gEditor.plugin = &plugin;
    }
    gEditor.panel.title = [NSString stringWithUTF8String:title.c_str()] ?: @"Plug-in";
    if (!gEditor.wanted) {
        int32_t w = 0, h = 0;
        if (!plugin.openEditor((__bridge void *)gEditor.panel.contentView, w, h, resized, nullptr, err)) return false;
        gFitPasses = 0;
        if (w > 0 && h > 0) [gEditor.panel setContentSize:NSMakeSize(w, h)];
        fit();
        // Editors that settle their size after joining the window (Apple's Audio Units) do so on the next turn of the
        // run loop, and fixed-size ones may change later (a disclosure opening): fit again whenever the view changes.
        NSView *view = gEditor.panel.contentView.subviews.firstObject;
        view.postsFrameChangedNotifications = YES;
        [NSNotificationCenter.defaultCenter addObserver:gEditor selector:@selector(editorFrameChanged:)
                                                   name:NSViewFrameDidChangeNotification object:view];
        dispatch_async(dispatch_get_main_queue(), ^{ fit(); });
        if (std::isnan(x) || std::isnan(y)) [gEditor.panel center];
        else [gEditor.panel setFrameTopLeftPoint:NSMakePoint(x, y)];
        // Dalnok asks for a place beside its own window without knowing the editor's size: keep it on screen.
        [gEditor.panel setFrame:onScreen(gEditor.panel.frame) display:NO];
        gEditor.wanted = YES;
    }
    [gEditor.panel orderFrontRegardless]; // the host is not active, so plain orderFront could leave it behind
    // Tests: press the title bar's Controls button once the window is up (DALNOK_TEST_EDITOR_CONTROLS=1).
    if (getenv("DALNOK_TEST_EDITOR_CONTROLS")) {
        for (NSTitlebarAccessoryViewController *a in gEditor.panel.titlebarAccessoryViewControllers)
            for (NSView *v in a.view.subviews)
                if ([v isKindOfClass:NSButton.class]) dispatch_async(dispatch_get_main_queue(), ^{ [(NSButton *)v performClick:nil]; });
    }
    if (NSApp.active) [gEditor hostBecameActive:nil];
    width = static_cast<int32_t>(gEditor.panel.contentView.frame.size.width);
    height = static_cast<int32_t>(gEditor.panel.contentView.frame.size.height);
    return true;
}

void closeEditor() {
    if (gEditor.panel && gEditor.wanted) [gEditor.panel close]; // windowWillClose closes the plug-in's view
}

EditorWindow editorWindow() {
    EditorWindow out;
    if (!gEditor.panel) return out;
    out.visible = gEditor.panel.visible;
    out.open = gEditor.wanted;
    const NSRect f = gEditor.panel.frame;
    out.x = f.origin.x; out.y = f.origin.y; out.width = f.size.width; out.height = f.size.height;
    const NSRect c = gEditor.panel.contentView.frame;
    out.contentWidth = c.size.width; out.contentHeight = c.size.height;
    out.windowNumber = gEditor.panel.windowNumber;
    out.level = gEditor.panel.level;
    return out;
}

bool snapshot(const std::string &path) {
    NSView *content = gEditor.panel.contentView;
    if (!content || !gEditor.wanted) return false;
    [content displayIfNeeded];
    NSBitmapImageRep *rep = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    if (!rep) return false;
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
    // Layer contents (plain layer-backed views, CA-drawn editors) are not always drawn by cacheDisplay: draw the layer
    // tree over it. The context already maps points to pixels, and AppKit's layers share its bottom-left origin.
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (ctx && content.layer) {
        CGContextSaveGState(ctx.CGContext);
        if (content.layer.geometryFlipped) {
            CGContextTranslateCTM(ctx.CGContext, 0, content.bounds.size.height);
            CGContextScaleCTM(ctx.CGContext, 1, -1);
        }
        [content.layer renderInContext:ctx.CGContext];
        CGContextRestoreGState(ctx.CGContext);
    }
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES];
}

} // namespace dalnok::hostui
