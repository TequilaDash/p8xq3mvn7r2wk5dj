//
//  zsigner.h
//  LiveContainer
//
//  Created by s s on 2024/11/10.
//
#import <Foundation/Foundation.h>


@interface ZSigner : NSObject
+ (NSProgress*)signWithAppPath:(NSString *)appPath bundleId:(NSString *)bundleId cert:(NSData *)key pass:(NSString *)pass completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (BOOL)adhocSignMachOAtPath:(NSString *)path bundleId:(NSString*)bundleId entitlementData:(NSData *)entitlementData;
+ (NSProgress*)signMachOPathArr:(NSArray<NSString*>*)machoPathArr bundleId:(NSString *)bundleId cert:(NSData *)key
                           pass:(NSString *)pass completionHandler:(void(^)(BOOL success, NSError *error))completionHandler;
// this method is used to get teamId for ADP/Enterprise certs ,don't use it in normal jitless
+ (NSString*)getTeamIdWithCert:(NSData *)cert pass:(NSString *)pass;
/// 本仓适配 (v0.3.832): 证书导入失败时取出 ZLog::logs 的具体原因（此前直接丢弃）。
/// getTeamIdWithCert 失败后调它，把详情写进 LoginLogger 的「证书管理」分类，
/// 让用户在 App 内就能看到失败根因，不用连 Mac Console。
+ (NSString*)lastZSignLogs;
+ (int)checkCert:(NSData *)cert pass:(NSString *)pass completionHandler:(void(^)(int status, NSDate* expirationDate, NSString* organizationalUnitName, NSString *error))completionHandler;
@end
