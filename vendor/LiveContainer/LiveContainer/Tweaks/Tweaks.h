//
//  Tweaks.h
//  LiveContainer
//
//  Created by s s on 2025/2/7.
//

void swizzle(Class class, SEL originalAction, SEL swizzledAction);
bool performHookDyldApi(const char* functionName, uint32_t adrpOffset, void** origFunction, void* hookFunction);

void NUDGuestHooksInit(void);
void SecItemGuestHooksInit(void);
void DyldHooksInit(bool hideLiveContainer, bool hookDlopen, uint32_t spoofSDKVersion);
void NSFMGuestHooksInit(void);
void NSFMGuestExtensionHooksInit(NSString *parentContainerPath);
void NSURLSCGuestHooksInit(void);
void initDead10ccFix(void);
void IDFVHookInit(NSUUID* uuid);
void NSExtensionGuestHooksInit(NSURL *appURL, NSURL *containerURL);
int LCRunGuestExtension(NSDictionary *request, NSExtensionContext *context);
NSString *LCPrepareGuestExtension(NSDictionary *request);

@interface NSBundle(LiveContainer)
- (instancetype)initWithPathForMainBundle:(NSString *)path;
@end


extern uint32_t appMainImageIndex;
extern void* appExecutableHandle;
extern bool tweakLoaderLoaded;
void* getGuestAppHeader(void);
void* getDSCAddr(void);
void* getCachedSymbol(NSString* symbolName, struct mach_header_64* header);
void saveCachedSymbol(NSString* symbolName, struct mach_header_64* header, uint64_t offset);
void* dlopen_nolock(const char *path, int mode);
void bypass_seg_count_check(void (^block)(void));

static void hook_do_nothing(void) {}
// 本仓功能 (C7, 重放于 9d6ea09b05 合入): 联网禁用钩子声明
void NetBlockGuestHooksInit(void);
void NetBlockApplyAfterGuestLoad(void);
// 本仓适配: 按**访客镜像**重绑（fishhook 对 chained fixups 无效，需要 litehook 按镜像地址改）.
void NetBlockApplyAfterGuestLoadWithImage(const struct mach_header_64 *header);
