/*
 * Copyright (c) 2010-2011 Apple Inc. All rights reserved.
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

#ifndef _OBJC_WEAK_H_
#define _OBJC_WEAK_H_

#include <objc/objc.h>
#include "objc-config.h"

__BEGIN_DECLS

/*
The weak table is a hash table governed by a single spin lock.
An allocated blob of memory, most often an object, but under GC any such 
allocation, may have its address stored in a __weak marked storage location 
through use of compiler generated write-barriers or hand coded uses of the 
register weak primitive. Associated with the registration can be a callback 
block for the case when one of the allocated chunks of memory is reclaimed. 
The table is hashed on the address of the allocated memory.  When __weak 
marked memory changes its reference, we count on the fact that we can still 
see its previous reference.

So, in the hash table, indexed by the weakly referenced item, is a list of 
all locations where this address is currently being stored.
 
For ARC, we also keep track of whether an arbitrary object is being 
deallocated by briefly placing it in the table just prior to invoking 
dealloc, and removing it via objc_clear_deallocating just prior to memory 
reclamation.

*/

// The address of a __weak variable.
// These pointers are stored disguised so memory analysis tools
// don't see lots of interior pointers from the weak table into objects.
typedef DisguisedPtr<objc_object *> weak_referrer_t;

#if __LP64__
#define PTR_MINUS_2 62
#else
#define PTR_MINUS_2 30
#endif

/**
 * The internal structure stored in the weak references table. 
 * It maintains and stores
 * a hash set of weak references pointing to an object.
 * If out_of_line_ness != REFERRERS_OUT_OF_LINE then the set
 * is instead a small inline array.
 */
#define WEAK_INLINE_COUNT 4

// out_of_line_ness field overlaps with the low two bits of inline_referrers[1].
// inline_referrers[1] is a DisguisedPtr of a pointer-aligned address.
// The low two bits of a pointer-aligned DisguisedPtr will always be 0b00
// (disguised nil or 0x80..00) or 0b11 (any other address).
// Therefore out_of_line_ness == 0b10 is used to mark the out-of-line state.
#define REFERRERS_OUT_OF_LINE 2

/// 弱引用element, 分2种存储方式(用线性存储, 哈希表存)👍
struct weak_entry_t {
    // 谁的weak属性
    DisguisedPtr<objc_object> referent;
    // 联合体, 每次只能用1个值
    union {
        // 这个是哈希表
        struct {
            // DisguisedPtr<objc_object *>
            weak_referrer_t *referrers;
            uintptr_t        out_of_line_ness : 2;
            // 存储的个数
            uintptr_t        num_refs : PTR_MINUS_2;
            // 容量
            uintptr_t        mask;
            uintptr_t        max_hash_displacement;
        };
        // 不是out_of_line的时候的数据, 这个是线性存储
        struct {
            // out_of_line_ness field is low bits of inline_referrers[1]
            weak_referrer_t  inline_referrers[WEAK_INLINE_COUNT];
        };
    };

    /// 用于判断是用的线性存储(inline_referrers)， 还是哈希表referrers
    /// true: 用referrers, false: inline_referrers
    bool out_of_line() {
        // referrers引用
        return (out_of_line_ness == REFERRERS_OUT_OF_LINE);
    }

    // copy
    weak_entry_t& operator=(const weak_entry_t& other) {
        memcpy(this, &other, sizeof(other));
        return *this;
    }

    /// 初始化newReferent对象的weak属性表, newReferrer添加进去
    weak_entry_t(objc_object *newReferent, objc_object **newReferrer)
        : referent(newReferent) {
            // 保存在第0个位置
        inline_referrers[0] = newReferrer;
        for (int i = 1; i < WEAK_INLINE_COUNT; i++) {
            // 其他位置清空
            inline_referrers[i] = nil;
        }
    }
};

/** 弱引用表, 哈希表
 * The global weak references table. Stores object ids as keys,
 * and weak_entry_t structs as their values.
 
 1.它是全局的, 只有一份
 2.通过求出哈希值来找到weak_entries[index].referent, 这就是referent对象的弱引用表
 3.weak_entry_t又分2种情况存储out_of_line: true哈希存储referrers, false线性存储inline_referrers
 */
struct weak_table_t {
    // 存储的weak
    weak_entry_t *weak_entries;
    // 存储的个数
    size_t    num_entries;
    // 表的size
    uintptr_t mask;
    uintptr_t max_hash_displacement;
};

/// referent_id对象添加referrer_id弱引用属性到它的weak表
/// Adds an (object, weak pointer) pair to the weak table.
id weak_register_no_lock(weak_table_t *weak_table, id referent, 
                         id *referrer, bool crashIfDeallocating);

/// 移除referent_id对象的weak表中的referrer_id数据
/// Removes an (object, weak pointer) pair from the weak table.
void weak_unregister_no_lock(weak_table_t *weak_table, id referent, id *referrer);

/// referent_id对象是否有weak属性表
#if DEBUG
/// Returns true if an object is weakly referenced somewhere.
bool weak_is_registered_no_lock(weak_table_t *weak_table, id referent);
#endif

/// 会在weak_table中，清空引用计数表并清除弱引用表，将所有weak引用指nil
/// Called on object destruction. Sets all remaining weak pointers to nil.
void weak_clear_no_lock(weak_table_t *weak_table, id referent);

__END_DECLS

#endif /* _OBJC_WEAK_H_ */
