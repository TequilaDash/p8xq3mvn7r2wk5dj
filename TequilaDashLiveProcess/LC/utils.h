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
// 崩溃实证 (0.3.881 .ips 112035/112050/112131): 嵌套场景下 hook_setDelegate 每次
// 都会再调 swizzle(UIWindow.makeKeyAndVisible/...)，method_exchangeImplementations
// 在 iOS 26 上对同一 (class,selector) 重复交换时 cache flush 段错误；
// 且重复交换会让 hook/orig 互换 (奇偶翻转)。这里按 (class,sel) 去重，只换一次。
// seen 由调用方以 __strong 静态存储传入 (地址即静态对象地址, 避免 __autoreleasing 误判).
static inline void td_swizzle_once(__strong NSMutableSet **seen, NSString *key, Class class,
                                   SEL originalAction, SEL swizzledAction, BOOL classMethod) {
    if (*seen == nil) {
        @synchronized ([NSUserDefaults class]) {
            if (*seen == nil) *seen = [NSMutableSet new];
        }
    }
    @synchronized (*seen) {
        if ([*seen containsObject:key]) return;
        [*seen addObject:key];
    }
    Method m1 = classMethod ? class_getClassMethod(class, originalAction) : class_getInstanceMethod(class, originalAction);
    Method m2 = classMethod ? class_getClassMethod(class, swizzledAction) : class_getInstanceMethod(class, swizzledAction);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

static inline void swizzle(Class class, SEL originalAction, SEL swizzledAction) {
    static NSMutableSet *tdSeen = nil;
    td_swizzle_once(&tdSeen,
                    [NSString stringWithFormat:@"%@:%@", NSStringFromClass(class), NSStringFromSelector(originalAction)],
                    class, originalAction, swizzledAction, NO);
}

static inline void swizzleClassMethod(Class class, SEL originalAction, SEL swizzledAction) {
    static NSMutableSet *tdSeen = nil;
    td_swizzle_once(&tdSeen,
                    [NSString stringWithFormat:@"+%@:%@", NSStringFromClass(class), NSStringFromSelector(originalAction)],
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
