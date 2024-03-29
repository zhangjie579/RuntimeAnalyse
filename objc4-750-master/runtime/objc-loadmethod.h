/*
 * Copyright (c) 2004-2006 Apple Inc.  All Rights Reserved.
 * 
 * @APPLE_LICENSE_HEADER_START@
 * 
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 * 
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 * 
 * @APPLE_LICENSE_HEADER_END@
 */

/***********************************************************************
* objc-loadmethod.h
* Support for +load methods.
**********************************************************************/

#ifndef _OBJC_LOADMETHOD_H
#define _OBJC_LOADMETHOD_H

#include "objc-private.h"

__BEGIN_DECLS

// 合并方法

extern void add_class_to_loadable_list(Class cls);
extern void add_category_to_loadable_list(Category cat);
extern void remove_class_from_loadable_list(Class cls);
extern void remove_category_from_loadable_list(Category cat);

extern void call_load_methods(void);

__END_DECLS

#endif
