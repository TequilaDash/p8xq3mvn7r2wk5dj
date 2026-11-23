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
void NSBundleGuestHooksInit(void);
void NSURLSCGuestHooksInit(void);
void initDead10ccFix(void);
void IDFVHookInit(NSUUID* uuid);

@interface NSBundle(LiveContainer)
- (instancetype)initWithPathForMainBundle:(NSString *)path;
@end


extern uint32_t appMainImageIndex;
extern void* appExecutableHandle;
extern bool tweakLoaderLoaded;
void* getGuestAppHeader(void);
uint32_t LCRealImageCount(void);
const char *tdv_masked_image_name(const char *realName);
const char *tdv_mask_real_prefix(void);
uint32_t LCGuestImageIndexForPath(const char *path);
// 备注客索引解析完成后重建"可见索引"表, 保证 guest 就是 index 0.
void LCRebuildImageRemap(void);
// Bootstrap only: after a successful guest dlopen and remap rebuild. Pass the
// path resolver's result (including UINT32_MAX), never the fallback index.
void LCSampleGuestImageMap(const char *guestPath, uint32_t resolvedGuestIndex);
// task_info(TASK_DYLD_INFO) interpose 的隐藏判定与可见索引表（Dyld.m 实现）。
// 隐藏规则与 _dyld_image_count 重绑一致；副本按同一顺序填充 infoArray。
bool TDVDyldInfoShouldHideImage(uint32_t realIndex);
uint32_t TDVDyldInfoVisibleIndices(uint32_t *out, uint32_t cap);
void* getDSCAddr(void);
void* getCachedSymbol(NSString* symbolName, struct mach_header_64* header);
void saveCachedSymbol(NSString* symbolName, struct mach_header_64* header, uint64_t offset);
void* dlopen_nolock(const char *path, int mode);
void bypass_seg_count_check(void (^block)(void));

static void hook_do_nothing(void) {}
