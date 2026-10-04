// Per-copy identity for scene bundles (spec §10).
//
// A "scene bundle" is a copy of PaperWalls.saver that stands for one scene,
// so it can appear as its own tile in System Settings. Every copy carries
// the same binary — and macOS loads every saver into one host process, so
// the Objective-C runtime keeps a single PaperWallsSaverView class for all
// of them and `Bundle(for:)` can't say which copy an instance came from.
//
// This constructor runs once per loaded IMAGE (each copy is its own Mach-O
// file, even if its classes are duplicates). It finds the bundle it lives
// in via its own code address, reads that bundle's unique NSPrincipalClass
// name, and registers a subclass of PaperWallsSaverView under that name
// whose +paperwallsBundlePath answers with the copy's own path. The host
// then instantiates that subclass, and the shared Swift code asks it where
// its bundle is.
//
// The main PaperWalls.saver keeps the plain principal class, so this is a
// no-op there (its NSPrincipalClass already exists).

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *PaperWallsBundlePathForThisImage(void) {
    Dl_info info;
    if (dladdr((const void *)&PaperWallsBundlePathForThisImage, &info) == 0 || info.dli_fname == NULL) {
        return nil;
    }
    // …/Name.saver/Contents/MacOS/PaperWalls → …/Name.saver
    NSString *executable = [NSString stringWithUTF8String:info.dli_fname];
    NSString *bundlePath = [[[executable stringByDeletingLastPathComponent]
                              stringByDeletingLastPathComponent]
                             stringByDeletingLastPathComponent];
    return [bundlePath.pathExtension isEqualToString:@"saver"] ? bundlePath : nil;
}

__attribute__((constructor))
static void PaperWallsRegisterSceneBundleClass(void) {
    @autoreleasepool {
        NSString *bundlePath = PaperWallsBundlePathForThisImage();
        if (bundlePath == nil) {
            return;
        }
        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        NSString *principalName = bundle.infoDictionary[@"NSPrincipalClass"];
        if (principalName.length == 0 || objc_getClass(principalName.UTF8String) != NULL) {
            return;   // the main saver, or already registered
        }
        Class base = objc_getClass("PaperWallsSaverView");
        if (base == NULL) {
            return;
        }
        Class sceneClass = objc_allocateClassPair(base, principalName.UTF8String, 0);
        if (sceneClass == NULL) {
            return;
        }
        NSString *capturedPath = [bundlePath copy];
        IMP pathIMP = imp_implementationWithBlock(^NSString *(id self) {
            return capturedPath;
        });
        class_addMethod(object_getClass(sceneClass), sel_registerName("paperwallsBundlePath"), pathIMP, "@@:");
        objc_registerClassPair(sceneClass);
    }
}
