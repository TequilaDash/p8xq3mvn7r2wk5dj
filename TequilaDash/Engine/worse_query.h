/*
 * worse_query - a containermanager query for iOS 26 and 27.
 * Copyright (C) 2026 Taj C
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version. It is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
 * PARTICULAR PURPOSE. See the GNU General Public License for more details.
 */

#ifndef worse_query_h
#define worse_query_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

/// Consume a sandbox extension for `path` through the App Group's Library/Caches.
///
/// `group` must be an App Group this app is entitled to; `alt_flags` is required
/// when targeting an App Group container on iOS 26.x. Returns a positive handle,
/// or a negative code.
int64_t worse_query(NSString *path, NSString *group, bool alt_flags, bool create_dir);

/// Release a handle from `worse_query`. Safe for negative handles.
void worse_query_release(int64_t handle);

/// App Group identifiers in this process's code signature. Empty if none.
NSArray<NSString *> *td_signed_app_groups(void);

#endif /* worse_query_h */