//
//  common.h — vendored from roothide/libroothide @ cb236f9 (MIT, see LICENSE).
//
//  本仓改造点 (其余逐字保留):
//  · 删除 `#define JB_ROOT_PARENT "/var/containers/Bundle/Application"` 硬编码。
//    上游 init.c 由「库自身位于 <JB_ROOT_PARENT>/.jbroot-<rand>/usr/lib/roothideinit.dylib」
//    推导 JBROOT；我们的 jbroot 落在 app 沙盒 Documents 内, 该常量必然不存在。
//    jbroot.c 的 rootfs_alloc 改为运行时从 __roothideinit_JBROOT 取父目录 (见该文件头)。
//  · __roothideinit_JBROOT 不再由构造器推导, 改由外部显式设置 (TDRootHideInit.{h,c})。
//

extern char** environ;

#define JB_ROOT_SYM  ".jbroot"
#define ROOTFS_NAME   "rootfs"

#define JB_ROOT_PREFIX ".jbroot-"
#define JB_RAND_LENGTH  (sizeof(uint64_t)*sizeof(char)*2)

#define IGNORE_JBRAND_VERIFY    0

#define EXPORT __attribute__ ((visibility ("default")))

int is_jbroot_name(const char* name);
unsigned long long resolve_jbrand_value(const char* name);

extern const char* __roothideinit_JBRAND;
extern const char* __roothideinit_JBROOT;

#include <sys/syslog.h>
#define SYSLOG(...) {openlog("roothide",LOG_PID,LOG_AUTH);syslog(LOG_DEBUG, __VA_ARGS__);closelog();}

#define JBPATH_LOG(...) {if(getenv("JBPATHLOG")&&atoi(getenv("JBPATHLOG"))) {printf(__VA_ARGS__);fflush(stdout);}}

#define VROOT_LOG(...) {if(getenv("VROOTLOG")&&atoi(getenv("VROOTLOG"))) {printf(__VA_ARGS__);fflush(stdout);}}

const char* getbacktrace(); //free after use
