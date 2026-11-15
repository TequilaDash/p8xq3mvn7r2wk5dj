#import <Foundation/Foundation.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>
#include <os/lock.h>
#define PrivClass(name) ((Class)objc_lookUpClass(#name))

const char **_CFGetProgname(void);
const char **_CFGetProcessPath(void);
int _NSGetExecutablePath(char* buf, uint32_t* bufsize);
int csops_audittoken(pid_t pid, unsigned int ops, void * useraddr, size_t usersize, audit_token_t * token);
#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
void os_unfair_recursive_lock_lock_with_options(void* lock, uint32_t options);
void os_unfair_recursive_lock_unlock(void* lock);
bool os_unfair_recursive_lock_trylock(void* lock);
bool os_unfair_recursive_lock_tryunlock4objc(void* lock);

struct dyld_all_image_infos *_alt_dyld_get_all_image_infos(void);
void *getDyldBase(void);
void init_bypassDyldLibValidation(void);
kern_return_t builtin_vm_protect(mach_port_name_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_max, vm_prot_t new_prot);
void *jitless_hook_dlopen(const char *path, int mode);

uint64_t aarch64_get_tbnz_jump_address(uint32_t instruction, uint64_t pc);
uint64_t aarch64_emulate_adrp(uint32_t instruction, uint64_t pc);
bool aarch64_emulate_add_imm(uint32_t instruction, uint32_t *dst, uint32_t *src, uint32_t *imm);
uint64_t aarch64_emulate_adrp_add(uint32_t instruction, uint32_t addInstruction, uint64_t pc);
uint64_t aarch64_emulate_adrp_ldr(uint32_t instruction, uint32_t ldrInstruction, uint64_t pc);

// 本仓适配 (M42, 2026-11-14): swizzle 幂等化.
// 崩溃实证 (0.3.881 .ips 112035/112050/112131): iOS 26 上对同一 (class,sel)
// 重复 method_exchangeImplementations 会 cache flush 段错误，且奇偶交换让
// hook/orig 互换。
// M42b (2026-11-14, .ips 151423 实证): 去重标记必须**跨镜像**共享。
// 嵌套场景下每个 LC 层都有各自的 TweakLoader/UIKit+GuestHooks 镜像, 各自的
// static 集合互相看不见 —— 两层各交换一次后, `hook_setDelegate` 槽位指向
// 第一层 hook 的 IMP, 尾调 `[self hook_setDelegate:]` 变成自指 → 21215 层
// 递归爆栈。改用 standardUserDefaults 布尔标记 (同进程所有镜像共享同一域):
// 同 (class,selector) 全进程只交换一次, 第二层镜像的 hook 保持未接线
// (其语义由第一层 hook 覆盖), 尾调链终止于真 original。
static inline bool td_swizzle_mark_once(NSString *key, Class class,
                                        SEL originalAction, SEL swizzledAction, BOOL classMethod) {
    NSString *mark = [NSString stringWithFormat:@"TD_swizzled_%@", key];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    @synchronized (defaults) {
        if ([defaults boolForKey:mark]) return false;
        [defaults setBool:YES forKey:mark];
    }
    Method m1 = classMethod ? class_getClassMethod(class, originalAction) : class_getInstanceMethod(class, originalAction);
    Method m2 = classMethod ? class_getClassMethod(class, swizzledAction) : class_getInstanceMethod(class, swizzledAction);
    if (!m1 || !m2) return false;
    method_exchangeImplementations(m1, m2);
    return true;
}

static inline void swizzle(Class class, SEL originalAction, SEL swizzledAction) {
    td_swizzle_mark_once([NSString stringWithFormat:@"%@:%@", NSStringFromClass(class), NSStringFromSelector(originalAction)],
                         class, originalAction, swizzledAction, NO);
}

static inline void swizzleClassMethod(Class class, SEL originalAction, SEL swizzledAction) {
    td_swizzle_mark_once([NSString stringWithFormat:@"+%@:%@", NSStringFromClass(class), NSStringFromSelector(originalAction)],
                         class, originalAction, swizzledAction, YES);
}

@interface NSUserDefaults(LiveContainer)
+ (instancetype)lcUserDefaults;
+ (instancetype)lcSharedDefaults;
+ (NSString *)lcAppGroupPath;
+ (NSString *)lcAppUrlScheme;
+ (NSBundle *)lcMainBundle;
+ (NSDictionary *)guestAppInfo;
+ (NSDictionary *)guestContainerInfo;
+ (bool)isLiveProcess;
+ (bool)isSharedApp;
+ (NSString*)lcGuestAppId;
+ (bool)isSideStore;
+ (bool)sideStoreExist;
+ (NSString*)lcLaunchURL;
@end

@interface NSDictionary(lc)
- (BOOL)writeBinToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile;
@end
