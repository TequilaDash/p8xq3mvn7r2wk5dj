@import Foundation;
@import MachO;

typedef void (^LCParseMachOCallback)(const char *path, struct mach_header_64 *header, int fd, void* filePtr);

#define PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER 1
#define PATCH_EXEC_RESULT_SEG_COUNT_MISMATCH 2

void LCPatchAppBundleFixupARM64eSlice(NSURL *bundleURL);
NSString *LCParseMachO(const char *path, bool readOnly, NS_NOESCAPE LCParseMachOCallback callback);
void LCPatchAddRPath(const char *path, struct mach_header_64 *header);
int LCPatchExecSlice(const char *path, struct mach_header_64 *header, bool doInject);
bool LCMachOExecutableHasDirtyTweakLoader(const char *path);
/// True when the executable carries its own anti-hook/anti-tamper guard
/// (currently the AISGuard family). Such binaries treat any injected
/// TweakLoader load command as tampering, so they must stay unpatched.
bool LCExecutableHasSelfIntegrityGuard(const char *path);
void LCChangeMachOUUID(struct mach_header_64 *header);
const uint8_t* LCGetMachOUUID(struct mach_header_64 *header);
bool LCIsMachOEncrypted(struct mach_header_64 *header);
uint64_t LCFindSymbolOffset(const char *basePath, const char *symbol);
struct mach_header_64 *LCGetLoadedImageHeader(int i0, const char* name);
NSString* getEntitlementXML(struct mach_header_64* header, void** entitlementXMLPtrOut);
NSString* getExecutableEntitlementXML(NSString* path);
bool checkCodeSignature(const char* path);
bool LCRepairTweakDependencies(const char *path, const char *substrateFrameworkPath);

// 反篡改: 读取安装时保存的原始主可执行备份 (<execPath>.td-original.executable),
// 把访客进程内存中被打补丁的 mach header / load commands 换回原始结构.
// LCLoadOriginalExecutableMachOHeader 把 arm64 slice 的 header + load commands
// 读进 malloc 缓冲区; *outHeaderSize = sizeof(mach_header_64) + sizeofcmds.
// 备份缺失 / fat 表越界 / sizeofcmds 非法时返回 false, *outHeader 置 NULL.
bool LCLoadOriginalExecutableMachOHeader(const char *execPath,
                                         struct mach_header_64 **outHeader,
                                         uint32_t *outHeaderSize);
// 在已加载镜像中定位访客主镜像 (优先校验过的 appMainImageIndex, 回退按
// exec path 匹配), 用原始 header + load commands 覆盖内存中被打补丁的前
// sizeof(mach_header_64)+origSizeofcmds 字节. 只动 header 区域, 不动
// __LINKEDIT, 不做 section 重映射; 幂等, 备份不存在时完全 no-op.
bool LCRestoreGuestExecutableMachOHeader(const char *execPath);
