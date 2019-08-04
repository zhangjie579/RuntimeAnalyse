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

#include "objc-private.h"

#include "objc-weak.h"

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <libkern/OSAtomic.h>

#define TABLE_SIZE(entry) (entry->mask ? entry->mask + 1 : 0)

/// entry添加新的referrer
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer);

BREAKPOINT_FUNCTION(
    void objc_weak_error(void)
);

#pragma mark - 弱引用struct

/// weak table错误
static void bad_weak_table(weak_entry_t *entries)
{
    _objc_fatal("bad weak table at %p. This may be a runtime bug or a "
                "memory error somewhere else.", entries);
}

/**  指针哈希值
 * Unique hash function for object pointers only.
 * 
 * @param key The object pointer
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t hash_pointer(objc_object *key) {
    return ptr_hash((uintptr_t)key);
}

/** 
 * Unique hash function for weak object pointers only.
 * 
 * @param key The weak object pointer. 
 * 
 * @return Size unrestricted hash of pointer.
 */
static inline uintptr_t w_hash_pointer(objc_object **key) {
    return ptr_hash((uintptr_t)key);
}

/** 扩容, 重新添加之前的, 插入新的new_referrer
 * 扩容旧的数据要重新添加过
 * Grow the entry's hash table of referrers. Rehashes each
 * of the referrers.
 * 
 * @param entry Weak pointer hash set for a particular object.
 */
__attribute__((noinline, used))
static void grow_refs_and_insert(weak_entry_t *entry, 
                                 objc_object **new_referrer) {
    assert(entry->out_of_line());

    // 1.size
    size_t old_size = TABLE_SIZE(entry);
    size_t new_size = old_size ? old_size * 2 : 8;

    // 2.扩容
    size_t num_refs = entry->num_refs;
    weak_referrer_t *old_refs = entry->referrers;
    entry->mask = new_size - 1;
    
    entry->referrers = (weak_referrer_t *)
        calloc(TABLE_SIZE(entry), sizeof(weak_referrer_t));
    entry->num_refs = 0;
    entry->max_hash_displacement = 0;
    
    // 3.添加旧的
    for (size_t i = 0; i < old_size && num_refs > 0; i++) {
        if (old_refs[i] != nil) {
            append_referrer(entry, old_refs[i]);
            num_refs--;
        }
    }
    // 4.插入新的
    // Insert
    append_referrer(entry, new_referrer);
    if (old_refs) free(old_refs);
}

/** 
 * Add the given referrer to set of weak pointers in this entry.
 * Does not perform duplicate checking (b/c weak pointers are never
 * added to a set twice). 
 *
 * @param entry The entry holding the set of weak pointers. 
 * @param new_referrer The new weak pointer to be added.
 */
static void append_referrer(weak_entry_t *entry, objc_object **new_referrer) {
    // 0.不是out_of_line, 即是线性存储
    if (!entry->out_of_line()) {
        // 1.找到inline_referrers空位插入
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == nil) {
                entry->inline_referrers[i] = new_referrer;
                return;
            }
        }

        // 2.没找到空位插入, 用更新存储方式out_of_line_ness, 用referrers存
        
        // 重写分配内存, 插入值, new_referrers为保存的inline_referrers数据
        // Couldn't insert inline. Allocate out of line.
        weak_referrer_t *new_referrers = (weak_referrer_t *)
            calloc(WEAK_INLINE_COUNT, sizeof(weak_referrer_t));
        // This constructed table is invalid, but grow_refs_and_insert
        // will fix it and rehash it.
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            new_referrers[i] = entry->inline_referrers[i];
        }
        
        // 把new_referrers赋值给referrers
        entry->referrers = new_referrers;
        entry->num_refs = WEAK_INLINE_COUNT;
        // 更新存储方式
        entry->out_of_line_ness = REFERRERS_OUT_OF_LINE;
        entry->mask = WEAK_INLINE_COUNT-1;
        entry->max_hash_displacement = 0;
    }

    assert(entry->out_of_line());

    // 3.扩容, 并插入new_referrer
    if (entry->num_refs >= TABLE_SIZE(entry) * 3/4) {
        return grow_refs_and_insert(entry, new_referrer);
    }
    
    // 4.容量合适, 不需要扩容, 找到插入的位置
    size_t begin = w_hash_pointer(new_referrer) & (entry->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    while (entry->referrers[index] != nil) {
        hash_displacement++;
        // 求哈希
        index = (index+1) & entry->mask;
        // 说明没找到
        if (index == begin) bad_weak_table(entry);
    }
    // 5.数量过大
    if (hash_displacement > entry->max_hash_displacement) {
        entry->max_hash_displacement = hash_displacement;
    }
    // 6.存新值
    weak_referrer_t &ref = entry->referrers[index];
    ref = new_referrer;
    entry->num_refs++;
}

/**  删除
 * Remove old_referrer from set of referrers, if it's present.
 * Does not remove duplicates, because duplicates should not exist. 
 * 
 * @todo this is slow if old_referrer is not present. Is this ever the case? 
 *
 * @param entry The entry holding the referrers.
 * @param old_referrer The referrer to remove. 
 */
static void remove_referrer(weak_entry_t *entry, objc_object **old_referrer)
{
    // 1.不是out_of_line的情况, 用inline_referrers
    if (!entry->out_of_line()) {
        // 顺序查找 ==, 就清空
        for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
            if (entry->inline_referrers[i] == old_referrer) {
                entry->inline_referrers[i] = nil;
                return;
            }
        }
        _objc_inform("Attempted to unregister unknown __weak variable "
                     "at %p. This is probably incorrect use of "
                     "objc_storeWeak() and objc_loadWeak(). "
                     "Break on objc_weak_error to debug.\n", 
                     old_referrer);
        objc_weak_error();
        return;
    }

    // 2.out_of_line的情况 - 从referrers中查找, 这是哈希表
    
    size_t begin = w_hash_pointer(old_referrer) & (entry->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    // 3.找到需要删除的old_referrer weak对象
    while (entry->referrers[index] != old_referrer) {
        // 3.1.求哈希值
        index = (index+1) & entry->mask;
        // 3.2.没找到
        if (index == begin) bad_weak_table(entry);
        hash_displacement++;
        // 3.3.过大, 就报错
        if (hash_displacement > entry->max_hash_displacement) {
            _objc_inform("Attempted to unregister unknown __weak variable "
                         "at %p. This is probably incorrect use of "
                         "objc_storeWeak() and objc_loadWeak(). "
                         "Break on objc_weak_error to debug.\n", 
                         old_referrer);
            objc_weak_error();
            return;
        }
    }
    
    // 4.找到就清空
    entry->referrers[index] = nil;
    entry->num_refs--;
}

#pragma mark - 弱引用表

/** 弱引用new_entry插入弱引用表weak_table
 * Add new_entry to the object's table of weak references.
 * Does not check whether the referent is already in the table.
 */
static void weak_entry_insert(weak_table_t *weak_table, weak_entry_t *new_entry)
{
    weak_entry_t *weak_entries = weak_table->weak_entries;
    assert(weak_entries != nil);

    size_t begin = hash_pointer(new_entry->referent) & (weak_table->mask);
    size_t index = begin;
    size_t hash_displacement = 0;
    // 1.找到插入的位置: 第1个weak_entries[index].referent = nil的地方
    while (weak_entries[index].referent != nil) {
        index = (index+1) & weak_table->mask;
        // 说明找不到出错了
        if (index == begin) bad_weak_table(weak_entries);
        hash_displacement++;
    }

    // 2.插入数据
    weak_entries[index] = *new_entry;
    weak_table->num_entries++;

    // 3.更新hash_displacement
    if (hash_displacement > weak_table->max_hash_displacement) {
        weak_table->max_hash_displacement = hash_displacement;
    }
}


/// 重置弱引用表的capacity
static void weak_resize(weak_table_t *weak_table, size_t new_size)
{
    // 1.旧的size
    size_t old_size = TABLE_SIZE(weak_table);

    // 2.新的、旧的weak引用数据
    weak_entry_t *old_entries = weak_table->weak_entries;
    weak_entry_t *new_entries = (weak_entry_t *)
        calloc(new_size, sizeof(weak_entry_t));

    // 3.重置weak_table的数据
    weak_table->mask = new_size - 1;
    weak_table->weak_entries = new_entries;
    weak_table->max_hash_displacement = 0;
    weak_table->num_entries = 0;  // restored by weak_entry_insert below
    
    // 4.旧的weak引用有值
    if (old_entries) {
        weak_entry_t *entry;
        // 结束值
        weak_entry_t *end = old_entries + old_size;
        // 5.遍历旧的weak引用
        for (entry = old_entries; entry < end; entry++) {
            // 有引用
            if (entry->referent) {
                // 6.弱引用插入弱引用表
                weak_entry_insert(weak_table, entry);
            }
        }
        // 是否旧的
        free(old_entries);
    }
}

// 重置table的容量capacity
// Grow the given zone's table of weak references if it is full.
static void weak_grow_maybe(weak_table_t *weak_table)
{
    size_t old_size = TABLE_SIZE(weak_table);

    // Grow if at least 3/4 full.
    if (weak_table->num_entries >= old_size * 3 / 4) {
        weak_resize(weak_table, old_size ? old_size*2 : 64);
    }
}

// weak table有一半空的就是重置table
// Shrink the table if it is mostly empty.
static void weak_compact_maybe(weak_table_t *weak_table)
{
    size_t old_size = TABLE_SIZE(weak_table);

    // Shrink if larger than 1024 buckets and at most 1/16 full.
    if (old_size >= 1024  && old_size / 16 >= weak_table->num_entries) {
        weak_resize(weak_table, old_size / 8);
        // leaves new table no more than 1/2 full
    }
}


/** 从全局的weak_table哈希表中移除, 某个对象的weak哈希表
 * Remove entry from the zone's table of weak references.
 */
static void weak_entry_remove(weak_table_t *weak_table, weak_entry_t *entry)
{
    // 1.哈希存储, 释放entry的哈希表
    if (entry->out_of_line()) free(entry->referrers);
    // 2.清空entry
    bzero(entry, sizeof(*entry));

    // 3.数量 - 1
    weak_table->num_entries--;

    // 4.重置capacity
    weak_compact_maybe(weak_table);
}


/** 找到第1个: weak_table->weak_entries[index].referent == referent, 即找到referent对象的弱引用表数据weak_entry_t
 * Return the weak reference table entry for the given referent. 
 * If there is no entry for referent, return NULL. 
 * Performs a lookup.
 *
 * @param weak_table 
 * @param referent The object. Must not be nil.
 * 
 * @return The table of weak referrers to this object. 
 */
static weak_entry_t *weak_entry_for_referent(weak_table_t *weak_table, objc_object *referent) {
    
    assert(referent);

    // 1.空表
    weak_entry_t *weak_entries = weak_table->weak_entries;

    if (!weak_entries) return nil;

    // 2.获取index
    size_t begin = hash_pointer(referent) & weak_table->mask;
    size_t index = begin;
    size_t hash_displacement = 0;
    
    // 3.找到第1个weak_entries[index].referent == referent
    // 先根据referent对象求出存储weak哈希表的哈希值
    // 由于解决哈希冲突是: 向后找空位, so就向后找到weak表的对象是referent
    while (weak_table->weak_entries[index].referent != referent) {
        // 3.1.更新index
        index = (index+1) & weak_table->mask;
        // 3.2.weak table错误, 就说明没找到
        if (index == begin) bad_weak_table(weak_table->weak_entries);
        hash_displacement++;
        // 3.3.比最大的个数还大
        if (hash_displacement > weak_table->max_hash_displacement) {
            return nil;
        }
    }
    
    // 4.说明找到
    return &weak_table->weak_entries[index];
}

/** 移除referent_id对象的weak表中的referrer_id数据
 * Unregister an already-registered weak reference.
 * This is used when referrer's storage is about to go away, but referent
 * isn't dead yet. (Otherwise, zeroing referrer later would be a
 * bad memory access.)
 * Does nothing if referent/referrer is not a currently active weak reference.
 * Does not zero referrer.
 * 
 * FIXME currently requires old referent value to be passed in (lame)
 * FIXME unregistration should be automatic if referrer is collected
 * 
 * @param weak_table The global weak table.
 * @param referent The object. referent对象的weak表
 * @param referrer The weak reference. 要清除的weak表中的数据
 */
// weak_unregister_no_lock(&oldTable->weak_table, oldObj, location);
void weak_unregister_no_lock(weak_table_t *weak_table,
                        // referent对象的weak表
                        id referent_id,
                        // 要清除的weak表中的数据
                        id *referrer_id) {
    // referent对象的weak表
    objc_object *referent = (objc_object *)referent_id;
    // 要清除的weak表中的数据
    objc_object **referrer = (objc_object **)referrer_id;

    weak_entry_t *entry;

    if (!referent) return;

    // 1.找到referent_id对应的weak表
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        // 2.从weak表中移除referrer_id
        remove_referrer(entry, referrer);
        
        // 3.看看weak表是不是empty
        bool empty = true;
        
        // 3.1.为哈希存储
        if (entry->out_of_line()  &&  entry->num_refs != 0) {
            empty = false;
        }
        else {
            // 3.2.为线性存储 - inline_referrers
            for (size_t i = 0; i < WEAK_INLINE_COUNT; i++) {
                if (entry->inline_referrers[i]) {
                    empty = false; 
                    break;
                }
            }
        }

        // 4.如果对象的weak表为空, 就从全局的弱引用哈希表中移除它
        if (empty) {
            weak_entry_remove(weak_table, entry);
        }
    }

    // Do not set *referrer = nil. objc_storeWeak() requires that the 
    // value not change.
}

/** referent_id对象添加referrer_id弱引用属性到它的weak表
 * Registers a new (object, weak pointer) pair. Creates a new weak
 * object entry if it does not exist.
 * 
 * @param weak_table The global weak table.
 * @param referent The object pointed to by the weak reference.
 * @param referrer The weak pointer address.
 */
id weak_register_no_lock(weak_table_t *weak_table,
                      // referent对象的weak表
                      id referent_id,
                      // 要添加到的weak表中的数据
                      id *referrer_id,
                      // 正在dealloc, crash
                      bool crashIfDeallocating) {
    // referent对象的weak表
    objc_object *referent = (objc_object *)referent_id;
    // weak表中的数据
    objc_object **referrer = (objc_object **)referrer_id;

    // 1.没有对象、是tag pointer, 直接返回
    if (!referent || referent->isTaggedPointer()) return referent_id;

    // 2.确定是否正在dealloc
    // ensure that the referenced object is viable
    bool deallocating;
    if (!referent->ISA()->hasCustomRR()) {
        deallocating = referent->rootIsDeallocating();
    }
    else {
        BOOL (*allowsWeakReference)(objc_object *, SEL) = 
            (BOOL(*)(objc_object *, SEL))
            object_getMethodImplementation((id)referent, 
                                           SEL_allowsWeakReference);
        if ((IMP)allowsWeakReference == _objc_msgForward) {
            return nil;
        }
        deallocating =
            ! (*allowsWeakReference)(referent, SEL_allowsWeakReference);
    }

    // 3.如果正在dealloc
    if (deallocating) {
        if (crashIfDeallocating) {
            _objc_fatal("Cannot form weak reference to instance (%p) of "
                        "class %s. It is possible that this object was "
                        "over-released, or is in the process of deallocation.",
                        (void*)referent, object_getClassName((id)referent));
        } else {
            return nil;
        }
    }

    // 4.找出referent的weak属性表, 把referrer插入
    // now remember it and where it is being stored
    weak_entry_t *entry;
    if ((entry = weak_entry_for_referent(weak_table, referent))) {
        append_referrer(entry, referrer);
    } 
    else {
        // 5.没找到referent对象的weak属性表
        
        // 初始化weak属性表
        weak_entry_t new_entry(referent, referrer);
        // 确保table的容量capacity
        weak_grow_maybe(weak_table);
        // 插入全局管理的weak table
        weak_entry_insert(weak_table, &new_entry);
    }

    // Do not set *referrer. objc_storeWeak() requires that the 
    // value not change.

    return referent_id;
}


/// referent_id对象是否有weak属性表
#if DEBUG
bool weak_is_registered_no_lock(weak_table_t *weak_table, id referent_id)
{
    return weak_entry_for_referent(weak_table, (objc_object *)referent_id);
}
#endif


/** 会在weak_table中，清空引用计数表并清除弱引用表，将所有weak引用指nil
 * Called by dealloc; nils out all weak pointers that point to the 
 * provided object so that they can no longer be used.
 * 
 * @param weak_table 全局的弱引用哈希表
 * @param referent The object being deallocated. 需要清除weak属性表的对象
 */
void weak_clear_no_lock(weak_table_t *weak_table, id referent_id) {
    // 1.objc_object需要清除weak属性表的对象
    objc_object *referent = (objc_object *)referent_id;

    // 2.找到对象的弱引用属性表
    weak_entry_t *entry = weak_entry_for_referent(weak_table, referent);
    if (entry == nil) {
        /// XXX shouldn't happen, but does with mismatched CF/objc
        //printf("XXX no entry for clear deallocating %p\n", referent);
        return;
    }

    // 3.获取weak引用数据
    // zero out references
    weak_referrer_t *referrers;
    size_t count;
    
    // 4.out_of_line是用哈希表的方式存储, 在referrers中
    if (entry->out_of_line()) {
        referrers = entry->referrers;
        count = TABLE_SIZE(entry);
    }
    // 4.2.用线性存储, 在inline_referrers
    else {
        referrers = entry->inline_referrers;
        count = WEAK_INLINE_COUNT;
    }
    
    // 5.遍历weak引用，找到 == 自己的设置为nil
    for (size_t i = 0; i < count; ++i) {
        objc_object **referrer = referrers[i];
        if (referrer) {
            // 找到 == referent_id的引用
            if (*referrer == referent) {
                *referrer = nil;
            }
            else if (*referrer) {
                _objc_inform("__weak variable at %p holds %p instead of %p. "
                             "This is probably incorrect use of "
                             "objc_storeWeak() and objc_loadWeak(). "
                             "Break on objc_weak_error to debug.\n", 
                             referrer, (void*)*referrer, (void*)referent);
                objc_weak_error();
            }
        }
    }
    
    // 3.移除weak引用数据
    weak_entry_remove(weak_table, entry);
}

