/*
 * Copyright (c) 1999-2001, 2005-2006 Apple Inc.  All Rights Reserved.
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
/*
	List.m
  	Copyright 1988-1996 NeXT Software, Inc.
	Written by: Bryan Yamamoto
	Responsibility: Bertrand Serlet
*/

#ifndef __OBJC2__

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include <objc/List.h>

#define DATASIZE(count) ((count) * sizeof(id))

@implementation  List

+ (id)initialize
{
    [self setVersion: 1];
    return self;
}

- (id)initCount:(unsigned)numSlots
{
    maxElements = numSlots;
    if (maxElements) 
	dataPtr = (id *)malloc(DATASIZE(maxElements));
    return self;
}

+ (id)newCount:(unsigned)numSlots
{
    return [[self alloc] initCount:numSlots];
}

+ (id)new
{
    return [self newCount:0];
}

- (id)init
{
    return [self initCount:0];
}

- (id)free
{
    free(dataPtr);
    return [super free];
}

- (id)freeObjects
{
    id element;
    while ((element = [self removeLastObject]))
	[element free];
    return self;
}

- (id)copyFromZone:(void *)z
{
    List	*new = [[[self class] alloc] initCount: numElements];
    new->numElements = numElements;
    bcopy ((const char*)dataPtr, (char*)new->dataPtr, DATASIZE(numElements));
    return new;
}

- (BOOL) isEqual: anObject
{
    List	*other;
    if (! [anObject isKindOf: [self class]]) return NO;
    other = (List *) anObject;
    return (numElements == other->numElements) 
    	&& (bcmp ((const char*)dataPtr, (const char*)other->dataPtr, DATASIZE(numElements)) == 0);
}

- (unsigned)capacity
{
    return maxElements;
}

- (unsigned)count
{
    return numElements;
}

- (id)objectAt:(unsigned)index
{
    if (index >= numElements)
	return nil;
    return dataPtr[index];
}

/// 顺序搜索
- (unsigned)indexOf:anObject {
    register id *this = dataPtr;
    // 最后一个的指针
    register id *last = this + numElements;
    // 遍历
    while (this < last) {
        // 找到就返回
        if (*this == anObject)
            return this - dataPtr;
        this++;
    }
    return NX_NOT_IN_LIST;
}

- (id)lastObject {
    if (!numElements)
        return nil;
    // 最后一个的地址
    return dataPtr[numElements - 1];
}

- (id)setAvailableCapacity:(unsigned)numSlots
{
    volatile id *tempDataPtr;
    if (numSlots < numElements) return nil;
    tempDataPtr = (id *) realloc (dataPtr, DATASIZE(numSlots));
    dataPtr = (id *)tempDataPtr;
    maxElements = numSlots;
    return self;
}

- (id)insertObject:anObject at:(unsigned)index {
    register id *this, *last, *prev;
    // 1.没值
    if (!anObject) return nil;
    // 2.越界了
    if (index > numElements)
        return nil;
    // 3.扩容
    if ((numElements + 1) > maxElements) {
        volatile id *tempDataPtr;
        /* we double the capacity, also a good size for malloc */
        maxElements += maxElements + 1;
        // 重新分配内存
        tempDataPtr = (id *) realloc (dataPtr, DATASIZE(maxElements));
        dataPtr = (id*)tempDataPtr;
    }
    
    // 已经存的后面一个位置
    this = dataPtr + numElements;
    // this的前一个
    prev = this - 1;
    // 插入的位置
    last = dataPtr + index;
    // 4.index ~ numElements - 1位置的, 需要后移一个位
    while (this > last) 
        *this-- = *prev--;
    // 5.插入anObject到index
    *last = anObject;
    // 数量 + 1
    numElements++;
    return self;
}

/// 添加 - 为插入到numElements位, 即已经存的后面一个位
- (id)addObject:anObject {
    return [self insertObject:anObject at:numElements];
}


- (id)addObjectIfAbsent:anObject
{
    register id *this, *last;
    if (! anObject) return nil;
    this = dataPtr;
    last = dataPtr + numElements;
    while (this < last) {
        if (*this == anObject)
	    return self;
	this++;
    }
    return [self insertObject:anObject at:numElements];
    
}


- (id)removeObjectAt:(unsigned)index
{
    register id *this, *last, *next;
    id retval;
    // 1.越界, 不管
    if (index >= numElements)
        return nil;
    // 2.index + 1 ~ numElements - 1的需要前移1位
    
    // 需要删除的位
    this = dataPtr + index;
    // 最后一位的后一位
    last = dataPtr + numElements;
    // 前移1位的start
    next = this + 1;
    retval = *this;
    // 循环, 前移, this = next
    while (next < last)
        *this++ = *next++;
    // 数量 - 1
    numElements--;
    // 返回index位的
    return retval;
}

- (id)removeObject:anObject
{
    register id *this, *last;
    this = dataPtr;
    last = dataPtr + numElements;
    while (this < last) {
        // 循环找到anObject的index
        if (*this == anObject)
            return [self removeObjectAt:this - dataPtr];
        this++;
    }
    return nil;
}

- (id)removeLastObject
{
    if (!numElements)
        return nil;
    return [self removeObjectAt: numElements - 1];
}

- (id)empty {
    numElements = 0;
    return self;
}

- (id)replaceObject:anObject with:newObject {
    register id *this, *last;
    if (! newObject)
        return nil;
    this = dataPtr;
    last = dataPtr + numElements;
    while (this < last) {
        // 找到anObject的指针, 然后改变为newObject
        if (*this == anObject) {
            *this = newObject;
            return anObject;
        }
        this++;
    }
    return nil;
}

- (id)replaceObjectAt:(unsigned)index with:newObject
{
    register id *this;
    id retval;
    if ( newObject)
        return nil;
    if (index >= numElements)
        return nil;
    // 加到index的指针
    this = dataPtr + index;
    retval = *this;
    // 改变为newObject
    *this = newObject;
    return retval;
}

- (id)makeObjectsPerform:(SEL)aSelector {
    unsigned	count = numElements;
    while (count--)
        [dataPtr[count] perform: aSelector];
    return self;
}

- (id)makeObjectsPerform:(SEL)aSelector with:anObject {
    unsigned	count = numElements;
    while (count--)
	[dataPtr[count] perform: aSelector with: anObject];
    return self;
}

-(id)appendList:(List *)otherList {
    unsigned i, count;
    
    for (i = 0, count = [otherList count]; i < count; i++)
        [self addObject: [otherList objectAt: i]];
    return self;
}

@end

#endif
