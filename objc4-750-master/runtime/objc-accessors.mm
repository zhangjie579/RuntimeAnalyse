/*
 * Copyright (c) 2006-2008 Apple Inc.  All Rights Reserved.
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

#include <string.h>
#include <stddef.h>

#include <libkern/OSAtomic.h>

#include "objc-private.h"
#include "runtime.h"

// stub interface declarations to make compiler happy.

@interface __NSCopyable
- (id)copyWithZone:(void *)zone;
@end

@interface __NSMutableCopyable
- (id)mutableCopyWithZone:(void *)zone;
@end

StripedMap<spinlock_t> PropertyLocks;
StripedMap<spinlock_t> StructLocks;
StripedMap<spinlock_t> CppObjectLocks;

#define MUTABLE_COPY 2

/// 原子属性获取value的时候有加锁
id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic) {
    // 1.偏移量为0, 返回self的isa
    if (offset == 0) {
        return object_getClass(self);
    }

    // 通过偏移量找到value
    id *slot = (id*) ((char*)self + offset);
    // 2.不是原子属性atomic, 返回
    if (!atomic) return *slot;
    
    // 3.原子属性, 在lock中objc_retain, 然后返回autorelease
    // Atomic retain release world
    spinlock_t& slotlock = PropertyLocks[slot];
    slotlock.lock();
    id value = objc_retain(*slot);
    slotlock.unlock();
    
    // for performance, we (safely) issue the autorelease OUTSIDE of the spinlock.
    // 注册到autorelease
    return objc_autoreleaseReturnValue(value);
}


static inline void reallySetProperty(id self, SEL _cmd, id newValue, ptrdiff_t offset, bool atomic, bool copy, bool mutableCopy) __attribute__((always_inline));

/// set方法
/// offset: 属性的偏移量
/// atomic: 是否为原子属性, 原子属性: 获取old、设置new的时候会加锁, new retain的时候没加锁, old release的时候也没加锁
/// copy、mutableCopy: 是否是copy、mutableCopy(浅拷贝与深拷贝), 分别会调用newValue的copyWithZone、mutableCopyWithZone来获取newValue
static inline void reallySetProperty(id self, SEL _cmd, id newValue, ptrdiff_t offset,
                                     bool atomic, bool copy, bool mutableCopy) {
    // 1.偏移量为0
    if (offset == 0) {
        object_setClass(self, newValue);
        return;
    }

    id oldValue;
    // 2.根据偏移量求出当前的oldValue的指针
    id *slot = (id*) ((char*)self + offset);

    // 3.不同的修饰类型，copy，mutableCopy，strong
    if (copy) { // 3.1.浅拷贝
        newValue = [newValue copyWithZone:nil];
    } else if (mutableCopy) { // 3.2.深拷贝
        newValue = [newValue mutableCopyWithZone:nil];
    } else {
        // 3.3.strong
        
        // 相等 -> 直接return
        if (*slot == newValue) return;
        // 强引用newValue
        newValue = objc_retain(newValue);
    }

    // 4.是否原子属性, 区别: 原子属性获取oldValue，set newValue加锁
    if (!atomic) {
        oldValue = *slot;
        *slot = newValue;
    } else {
        spinlock_t& slotlock = PropertyLocks[slot];
        slotlock.lock();
        // 获取oldValue，set newValue加锁 👍
        oldValue = *slot;
        *slot = newValue;        
        slotlock.unlock();
    }

    // 5.释放 oldValue
    objc_release(oldValue);
}

void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, signed char shouldCopy) {
    // 应该copy, 并且 != mutable copy
    bool copy = (shouldCopy && shouldCopy != MUTABLE_COPY);
    // 为mutable copy
    bool mutableCopy = (shouldCopy == MUTABLE_COPY);
    reallySetProperty(self, _cmd, newValue, offset, atomic, copy, mutableCopy);
}

void objc_setProperty_atomic(id self, SEL _cmd, id newValue, ptrdiff_t offset) {
    // atomic为true
    // copy、mutableCopy全为false
    reallySetProperty(self, _cmd, newValue, offset, true, false, false);
}

void objc_setProperty_nonatomic(id self, SEL _cmd, id newValue, ptrdiff_t offset) {
    // atomic、copy、mutableCopy全为false
    reallySetProperty(self, _cmd, newValue, offset, false, false, false);
}


void objc_setProperty_atomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset) {
    // atomic、copy为true
    // mutableCopy全为false
    reallySetProperty(self, _cmd, newValue, offset, true, true, false);
}

void objc_setProperty_nonatomic_copy(id self, SEL _cmd, id newValue, ptrdiff_t offset) {
    reallySetProperty(self, _cmd, newValue, offset, false, true, false);
}


// This entry point was designed wrong.  When used as a getter, src needs to be locked so that
// if simultaneously used for a setter then there would be contention on src.
// So we need two locks - one of which will be contended.
void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong __unused) {
    spinlock_t *srcLock = nil;
    spinlock_t *dstLock = nil;
    // 原子属性2个指针全加锁
    if (atomic) {
        srcLock = &StructLocks[src];
        dstLock = &StructLocks[dest];
        spinlock_t::lockTwo(srcLock, dstLock);
    }

    // 从src内存地址开始, 移动size大小的值到dest
    // 移动旧值可能会清空
    memmove(dest, src, size);

    // 解锁
    if (atomic) {
        spinlock_t::unlockTwo(srcLock, dstLock);
    }
}

void objc_copyCppObjectAtomic(void *dest, const void *src, void (*copyHelper) (void *dest, const void *source)) {
    spinlock_t *srcLock = &CppObjectLocks[src];
    spinlock_t *dstLock = &CppObjectLocks[dest];
    spinlock_t::lockTwo(srcLock, dstLock);

    // let C++ code perform the actual copy.
    copyHelper(dest, src);
    
    spinlock_t::unlockTwo(srcLock, dstLock);
}
