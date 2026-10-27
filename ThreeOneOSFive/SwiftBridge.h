#ifndef FLUXCORE_SWIFT_BRIDGE_H
#define FLUXCORE_SWIFT_BRIDGE_H

// Keep the Swift bridging surface deliberately small.
// The implementation headers remain available to their native Obj-C/C files;
// Swift only imports the C/Obj-C entry points it actually calls.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdbool.h>
#include <stdint.h>
#include "kexploit/kutils.h"

// exploit/bad_query.h
int64_t bad_query(char *path, bool create, char *group_identifier, bool is_group);
char *bad_query_list(char *path, int64_t max_inode);
void bad_query_release(int64_t handle);

// exploit/mcm_bridge.h
NS_ASSUME_NONNULL_BEGIN
NSArray<NSString *> *MCMEnumerateIdentifiersForClass(
    uint64_t cls,
    NSUInteger limit,
    NSString * _Nullable * _Nullable error
);
NSString * _Nullable MCMActivateContainerPath(
    uint64_t cls,
    NSString *identifier,
    BOOL group,
    NSString * _Nullable * _Nullable error
);
int64_t MCMActivateContainer(
    uint64_t cls,
    NSString *identifier,
    BOOL group,
    NSString * _Nullable * _Nullable error
);
NS_ASSUME_NONNULL_END

// kexploit/kexploit_opa334.h — Swift only needs the entry point.
int kexploit_opa334(void);

// kexploit/sandbox_escape.h
int sandbox_access_is_active(void);
int sandbox_escape(uint64_t self_proc);

// helpers/DisplayIdentity.h
NSString *DisplayIdentityAttestationToken(void);
NSURL *DisplayIdentityAttributionURL(void);

// helpers/AppIconHelper.h
NSDictionary<NSString *, NSDictionary *> *installedAppInfo(void);
UIImage * _Nullable iconForBundleID(NSString *bundleID);
NSDictionary *appInfoForBundleID(NSString *bundleID);
BOOL openApplicationForBundleID(NSString *bundleID);

#endif /* FLUXCORE_SWIFT_BRIDGE_H */
