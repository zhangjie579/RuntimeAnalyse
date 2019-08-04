/*
 * Copyright (c) 1999-2008 Apple Inc.  All Rights Reserved.
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
/* 哈希表
	hashtable2.m
  	Copyright 1989-1996 NeXT Software, Inc.
	Created by Bertrand Serlet, Feb 89
 */

#include "objc-private.h"
#include "hashtable2.h"

/* In order to improve efficiency, buckets contain a pointer to an array or directly the data when the array size is 1 */
typedef union {
    // NXHashTablePrototype *
    const void	*one;
    // NXHashTablePrototype **, 多个
    const void	**many;
} oneOrMany;
    /* an optimization consists of storing directly data when count = 1 */
    
typedef struct	{
    // 个数, 每一项还可以存多个在
    unsigned 	count; 
    oneOrMany	elements;
} HashBucket;
    /* private data structure; may change */
    
/*************************************************************************
 *
 *	Macros and utilities
 *	
 *************************************************************************/

#define	PTRSIZE		sizeof(void *)

#if !SUPPORT_ZONES
#   define	DEFAULT_ZONE	 NULL
#   define	ZONE_FROM_PTR(p) NULL
#   define	ALLOCTABLE(z)	((NXHashTable *) malloc (sizeof (NXHashTable)))
#   define	ALLOCBUCKETS(z,nb)((HashBucket *) calloc (nb, sizeof (HashBucket)))
/* Return interior pointer so a table of classes doesn't look like objects */
#   define	ALLOCPAIRS(z,nb) (1+(const void **) calloc (nb+1, sizeof (void *)))
#   define	FREEPAIRS(p) (free((void*)(-1+p)))
#else
#   define	DEFAULT_ZONE	 malloc_default_zone()
#   define	ZONE_FROM_PTR(p) malloc_zone_from_ptr(p)
#   define	ALLOCTABLE(z)	((NXHashTable *) malloc_zone_malloc ((malloc_zone_t *)z,sizeof (NXHashTable)))
#   define	ALLOCBUCKETS(z,nb)((HashBucket *) malloc_zone_calloc ((malloc_zone_t *)z, nb, sizeof (HashBucket)))
/* Return interior pointer so a table of classes doesn't look like objects */
#   define	ALLOCPAIRS(z,nb) (1+(const void **) malloc_zone_calloc ((malloc_zone_t *)z, nb+1, sizeof (void *)))
#   define	FREEPAIRS(p) (free((void*)(-1+p)))
#endif

#if !SUPPORT_MOD
    /* nbBuckets must be a power of 2 */
#   define BUCKETOF(table, data) (((HashBucket *)table->buckets)+((*table->prototype->hash)(table->info, data) & (table->nbBuckets-1)))
#   define GOOD_CAPACITY(c) (c <= 1 ? 1 : 1 << (log2u (c-1)+1))
#   define MORE_CAPACITY(b) (b*2)
#else
    /* iff necessary this modulo can be optimized since the nbBuckets is of the form 2**n-1 */
#   define	BUCKETOF(table, data) (((HashBucket *)table->buckets)+((*table->prototype->hash)(table->info, data) % table->nbBuckets))
#   define GOOD_CAPACITY(c) (exp2m1u (log2u (c)+1))
#   define MORE_CAPACITY(b) (b*2+1)
#endif

#define ISEQUAL(table, data1, data2) ((data1 == data2) || (*table->prototype->isEqual)(table->info, data1, data2))
	/* beware of double evaluation */
	
/*************************************************************************
 *
 *	Global data and bootstrap
 *	
 *************************************************************************/

/// NXHashTablePrototype isEqual, data是NXHashTablePrototype
static int isEqualPrototype (const void *info, const void *data1, const void *data2) {
    NXHashTablePrototype	*proto1 = (NXHashTablePrototype *) data1;
    NXHashTablePrototype	*proto2 = (NXHashTablePrototype *) data2;
    
    return (proto1->hash == proto2->hash) && (proto1->isEqual == proto2->isEqual) && (proto1->free == proto2->free) && (proto1->style == proto2->style);
    };

/// NXHashTablePrototype哈希值
static uintptr_t hashPrototype (const void *info, const void *data) {
    NXHashTablePrototype	*proto = (NXHashTablePrototype *) data;
    
    return NXPtrHash(info, (void*)proto->hash) ^ NXPtrHash(info, (void*)proto->isEqual) ^ NXPtrHash(info, (void*)proto->free) ^ (uintptr_t) proto->style;
    };

/// free
void NXNoEffectFree (const void *info, void *data) {};

static NXHashTablePrototype protoPrototype = {
    hashPrototype, isEqualPrototype, NXNoEffectFree, 0
};

/// 用这个保存
static NXHashTable *prototypes = NULL;
	/* table of all prototypes */

/// 初始化static NXHashTable *prototypes
static void bootstrap (void) {
    free(malloc(8));
    prototypes = ALLOCTABLE (DEFAULT_ZONE);
    prototypes->prototype = &protoPrototype;
    // 初始化的时候是1个
    prototypes->count = 1;
    prototypes->nbBuckets = 1; /* has to be 1 so that the right bucket is 0 */
    // 给存的值分配内存
    prototypes->buckets = ALLOCBUCKETS(DEFAULT_ZONE, 1);
    prototypes->info = NULL;
    // 给存的1个value赋值
    ((HashBucket *) prototypes->buckets)[0].count = 1;
    ((HashBucket *) prototypes->buckets)[0].elements.one = &protoPrototype;
};

/// 指针是否 ==
int NXPtrIsEqual (const void *info, const void *data1, const void *data2) {
    return data1 == data2;
};

/*************************************************************************
 *
 *	On z'y va
 *	
 *************************************************************************/

/// 创建哈希表，用的是默认zone
NXHashTable *NXCreateHashTable (NXHashTablePrototype prototype, unsigned capacity, const void *info) {
    return NXCreateHashTableFromZone(prototype, capacity, info, DEFAULT_ZONE);
}

/// 创建哈希表
NXHashTable *NXCreateHashTableFromZone (NXHashTablePrototype prototype, unsigned capacity, const void *info, void *z) {
    NXHashTable			*table;
    NXHashTablePrototype	*proto;
    
    // 1.分配内存
    table = ALLOCTABLE(z);
    // 2.全局的哈希表是否有值, 没有就create
    if (! prototypes) bootstrap ();
    // 3.传入参数的属性没值就给默认的
    if (! prototype.hash) prototype.hash = NXPtrHash;
    if (! prototype.isEqual) prototype.isEqual = NXPtrIsEqual;
    if (! prototype.free) prototype.free = NXNoEffectFree;
    
    // 4.style != 0, 就返回nil
    if (prototype.style) {
        _objc_inform ("*** NXCreateHashTable: invalid style\n");
        return NULL;
	};
    // 5.从prototypes哈希表中取NXHashTablePrototype
    proto = (NXHashTablePrototype *)NXHashGet (prototypes, &prototype);
    // 6.没有
    if (! proto) {
        // 分配内存
        proto = (NXHashTablePrototype *) malloc(sizeof (NXHashTablePrototype));
        bcopy ((const char*)&prototype, (char*)proto, sizeof (NXHashTablePrototype));
            (void) NXHashInsert (prototypes, proto);
        proto = (NXHashTablePrototype *)NXHashGet (prototypes, &prototype);
        if (! proto) {
            _objc_inform ("*** NXCreateHashTable: bug\n");
            return NULL;
            };
	};
    table->prototype = proto; table->count = 0; table->info = info;
    table->nbBuckets = GOOD_CAPACITY(capacity);
    table->buckets = ALLOCBUCKETS(z, table->nbBuckets);
    return table;
    }

/// 释放
static void freeBucketPairs (void (*freeProc)(const void *info, void *data), HashBucket bucket, const void *info) {
    unsigned	j = bucket.count;
    const void	**pairs;
    
    // 1.只有1个free one
    if (j == 1) {
        (*freeProc) (info, (void *) bucket.elements.one);
        return;
	};
    
    // 2.有多个释放many
    pairs = bucket.elements.many;
    // 循环到j = 0, many也就没有了
    while (j--) {
        (*freeProc) (info, (void *) *pairs);
        pairs ++;
	};
    FREEPAIRS (bucket.elements.many);
};

/// 释放buckets
static void freeBuckets (NXHashTable *table, int freeObjects) {
    unsigned		i = table->nbBuckets;
    HashBucket		*buckets = (HashBucket *) table->buckets;
    
    // 循环table的容量
    while (i--) {
        // buckets不为空, free
        if (buckets->count) {
            freeBucketPairs ((freeObjects) ? table->prototype->free : NXNoEffectFree, *buckets, table->info);
            buckets->count = 0;
            buckets->elements.one = NULL;
        };
        // 下一个buckets
        buckets++;
	};
};

/// 释放整个哈希表
void NXFreeHashTable (NXHashTable *table) {
    freeBuckets (table, YES);
    free (table->buckets);
    free (table);
};

/// 清空哈希表为0
void NXEmptyHashTable (NXHashTable *table) {
    // 不是调用的prototype->free, 而是NXNoEffectFree
    freeBuckets (table, NO);
    table->count = 0;
}

/// 重置哈希表
void NXResetHashTable (NXHashTable *table) {
    freeBuckets (table, YES);
    table->count = 0;
}

BOOL NXCompareHashTables (NXHashTable *table1, NXHashTable *table2) {
    // 1.指针 ==
    if (table1 == table2) return YES;
    // 2.个数
    if (NXCountHashTable (table1) != NXCountHashTable (table2)) return NO;
    else {
        void		*data;
        NXHashState	state = NXInitHashState (table1);
        while (NXNextHashState (table1, &state, &data)) {
            // 看table中是否有data
            if (!NXHashMember (table2, data)) return NO;
        }
        return YES;
    }
}

NXHashTable *NXCopyHashTable (NXHashTable *table) {
    NXHashTable		*newt;
    NXHashState		state = NXInitHashState (table);
    void		*data;
    __unused void	*z = ZONE_FROM_PTR(table);
    
    newt = ALLOCTABLE(z);
    newt->prototype = table->prototype; newt->count = 0;
    newt->info = table->info;
    newt->nbBuckets = table->nbBuckets;
    newt->buckets = ALLOCBUCKETS(z, newt->nbBuckets);
    while (NXNextHashState (table, &state, &data))
        NXHashInsert (newt, data);
    return newt;
}

unsigned NXCountHashTable (NXHashTable *table) {
    return table->count;
}

/// 看table中是否有data
int NXHashMember (NXHashTable *table, const void *data) {
    HashBucket	*bucket = BUCKETOF(table, data);
    unsigned	j = bucket->count;
    const void	**pairs;
    
    // 1.table为空
    if (!j) return 0;
    // 2.1个, 比较是否相同
    if (j == 1) {
    	return ISEQUAL(table, data, bucket->elements.one);
	};
    
    // 3.多个, 找到相同的就返回1
    pairs = bucket->elements.many;
    while (j--) {
        /* we don't cache isEqual because lists are short */
    	if (ISEQUAL(table, data, *pairs)) return 1; 
        pairs ++;
	};
    // 4.到这说明没相同的
    return 0;
}

// NXHashTablePrototype *, data: NXHashTablePrototype
// 从哈希表中取NXHashTablePrototype
void *NXHashGet (NXHashTable *table, const void *data) {
    // 1.获取存的value
    HashBucket	*bucket = BUCKETOF(table, data);
    unsigned	j = bucket->count;
    const void	**pairs;
    
    // 2.个数为0
    if (! j) return NULL;
    // 3.个数为1
    if (j == 1) {
        // 2个data相同就返回, 否则为nil
    	return ISEQUAL(table, data, bucket->elements.one)
	    ? (void *) bucket->elements.one : NULL; 
	};
    
    // 4.到这说明 count > 1
    
    pairs = bucket->elements.many;
    while (j--) {
        /* we don't cache isEqual because lists are short */
        // == 就返回
    	if (ISEQUAL(table, data, *pairs)) return (void *) *pairs;
        // 后面一个
        pairs ++;
	};
    // 5.返回nil
    return NULL;
}

/// 哈希表的容量capacity
unsigned _NXHashCapacity (NXHashTable *table) {
    return table->nbBuckets;
}

/// 哈希表扩容
void _NXHashRehashToCapacity (NXHashTable *table, unsigned newCapacity) {
    /* Rehash: we create a pseudo table pointing really to the old guys,
    extend self, copy the old pairs, and free the pseudo table */
    NXHashTable	*old;
    NXHashState	state;
    void	*aux;
    // 1.zone
    __unused void *z = ZONE_FROM_PTR(table);
    
    // 2.分配内存
    old = ALLOCTABLE(z);
    // 把table的值copy给old, 浅copy
    old->prototype = table->prototype; old->count = table->count; 
    old->nbBuckets = table->nbBuckets; old->buckets = table->buckets;
    
    // 3.更新nbBuckets
    table->nbBuckets = newCapacity;
    table->count = 0; table->buckets = ALLOCBUCKETS(z, table->nbBuckets);
    // 4.init NXHashState
    state = NXInitHashState (old);
    // 5.把old的哈希value计算过哈希值，然后存在table的对应位置
    while (NXNextHashState (old, &state, &aux))
        (void) NXHashInsert (table, aux);
    // 6.释放old
    freeBuckets (old, NO);
    if (old->count != table->count)
        _objc_inform("*** hashtable: count differs after rehashing; probably indicates a broken invariant: there are x and y such as isEqual(x, y) is TRUE but hash(x) != hash (y)\n");
    free (old->buckets);
    free (old);
}

/// 扩容, 个数为table->nbBuckets * 2 + 1
static void _NXHashRehash (NXHashTable *table) {
    _NXHashRehashToCapacity (table, MORE_CAPACITY(table->nbBuckets));
}

/// 哈希表中插入值, 返回值是之前有存相同哈希的old值
void *NXHashInsert (NXHashTable *table, const void *data) {
    HashBucket	*bucket = BUCKETOF(table, data);
    unsigned	j = bucket->count;
    const void	**pairs;
    const void	**newt;
    __unused void *z = ZONE_FROM_PTR(table);
    
    // 1.没值
    if (! j) {
        // 保存date
        bucket->count++; bucket->elements.one = data;
        table->count++;
        return NULL;
	};
    // 2.有1个值
    if (j == 1) {
        // 2.1.== data, 更新存的值，返回old
    	if (ISEQUAL(table, data, bucket->elements.one)) {
            const void	*old = bucket->elements.one;
            bucket->elements.one = data;
            return (void *) old;
	    };
        // 2.2.到这说明 ！= data
        
        // 分配2个空间
        newt = ALLOCPAIRS(z, 2);
        // 0的位置为data, 1的位置为原来的
        newt[1] = bucket->elements.one;
        *newt = data;
        // 赋值给many, 数量 + 1
        bucket->count++; bucket->elements.many = newt;
        table->count++;
        // 3.超过了阈值, 扩容
        if (table->count > table->nbBuckets) _NXHashRehash (table);
        return NULL;
	};
    pairs = bucket->elements.many;
    // 3.遍历pairs
    while (j--) {
        /* we don't cache isEqual because lists are short */
        // == 就更新, 并返回old
    	if (ISEQUAL(table, data, *pairs)) {
            const void	*old = *pairs;
            *pairs = data;
            return (void *) old;
	    };
        // 找pairs下一个元素
        pairs ++;
	};
    
    // 4.到这说明没找到相同的值, 需要存
    
    /* we enlarge this bucket; and put new data in front */
    // 4.1.容量 + 1
    newt = ALLOCPAIRS(z, bucket->count+1);
    // 把many copy到新分配的上
    if (bucket->count) bcopy ((const char*)bucket->elements.many, (char*)(newt+1), bucket->count * PTRSIZE);
    // 最后一个值
    *newt = data;
    // 释放
    FREEPAIRS (bucket->elements.many);
    // count + 1, 更新many
    bucket->count++; bucket->elements.many = newt; 
    table->count++;
    
    // 5.容量过大就扩容
    if (table->count > table->nbBuckets) _NXHashRehash (table);
    
    // 6.之前没有相同的值，返回nil
    return NULL;
}

void *NXHashInsertIfAbsent (NXHashTable *table, const void *data) {
    HashBucket	*bucket = BUCKETOF(table, data);
    unsigned	j = bucket->count;
    const void	**pairs;
    const void	**newt;
    __unused void *z = ZONE_FROM_PTR(table);
    
    if (! j) {
	bucket->count++; bucket->elements.one = data; 
	table->count++; 
	return (void *) data;
	};
    if (j == 1) {
    	if (ISEQUAL(table, data, bucket->elements.one))
	    return (void *) bucket->elements.one;
	newt = ALLOCPAIRS(z, 2);
	newt[1] = bucket->elements.one;
	*newt = data;
	bucket->count++; bucket->elements.many = newt; 
	table->count++; 
	if (table->count > table->nbBuckets) _NXHashRehash (table);
	return (void *) data;
	};
    pairs = bucket->elements.many;
    while (j--) {
	/* we don't cache isEqual because lists are short */
    	if (ISEQUAL(table, data, *pairs))
	    return (void *) *pairs;
	pairs ++;
	};
    /* we enlarge this bucket; and put new data in front */
    newt = ALLOCPAIRS(z, bucket->count+1);
    if (bucket->count) bcopy ((const char*)bucket->elements.many, (char*)(newt+1), bucket->count * PTRSIZE);
    *newt = data;
    FREEPAIRS (bucket->elements.many);
    bucket->count++; bucket->elements.many = newt; 
    table->count++; 
    if (table->count > table->nbBuckets) _NXHashRehash (table);
    return (void *) data;
    }

void *NXHashRemove (NXHashTable *table, const void *data) {
    HashBucket	*bucket = BUCKETOF(table, data);
    unsigned	j = bucket->count;
    const void	**pairs;
    const void	**newt;
    __unused void *z = ZONE_FROM_PTR(table);
    
    if (! j) return NULL;
    if (j == 1) {
	if (! ISEQUAL(table, data, bucket->elements.one)) return NULL;
	data = bucket->elements.one;
	table->count--; bucket->count--; bucket->elements.one = NULL;
	return (void *) data;
	};
    pairs = bucket->elements.many;
    if (j == 2) {
    	if (ISEQUAL(table, data, pairs[0])) {
	    bucket->elements.one = pairs[1]; data = pairs[0];
	    }
	else if (ISEQUAL(table, data, pairs[1])) {
	    bucket->elements.one = pairs[0]; data = pairs[1];
	    }
	else return NULL;
	FREEPAIRS (pairs);
	table->count--; bucket->count--;
	return (void *) data;
	};
    while (j--) {
    	if (ISEQUAL(table, data, *pairs)) {
	    data = *pairs;
	    /* we shrink this bucket */
	    newt = (bucket->count-1) 
		? ALLOCPAIRS(z, bucket->count-1) : NULL;
	    if (bucket->count-1 != j)
		    bcopy ((const char*)bucket->elements.many, (char*)newt, PTRSIZE*(bucket->count-j-1));
	    if (j)
		    bcopy ((const char*)(bucket->elements.many + bucket->count-j), (char*)(newt+bucket->count-j-1), PTRSIZE*j);
	    FREEPAIRS (bucket->elements.many);
	    table->count--; bucket->count--; bucket->elements.many = newt;
	    return (void *) data;
	    };
	pairs ++;
	};
    return NULL;
    }

NXHashState NXInitHashState (NXHashTable *table) {
    NXHashState	state;
    
    state.i = table->nbBuckets;
    state.j = 0;
    return state;
};
    
int NXNextHashState (NXHashTable *table, NXHashState *state, void **data) {
    HashBucket		*buckets = (HashBucket *) table->buckets;
    
    while (state->j == 0) {
        if (state->i == 0) return NO;
        
        // 到这说明i != 0, j == 0
        state->i--;
        // 把对应位置的是count赋上
        state->j = buckets[state->i].count;
	}
    state->j--;
    buckets += state->i;
    // 把值copy给data
    *data = (void *) ((buckets->count == 1) 
    		? buckets->elements.one : buckets->elements.many[state->j]);
    return YES;
};

/*************************************************************************
 *
 *	Conveniences
 *	
 *************************************************************************/

/// 指针的哈希
uintptr_t NXPtrHash (const void *info, const void *data) {
    // 保证只有16位
    return (((uintptr_t) data) >> 16) ^ ((uintptr_t) data);
    };

/// string的哈希
uintptr_t NXStrHash (const void *info, const void *data) {
    uintptr_t	hash = 0;
    unsigned char	*s = (unsigned char *) data;
    /* unsigned to avoid a sign-extend */
    /* unroll the loop */
    if (s) for (; ; ) { 
	if (*s == '\0') break;
	hash ^= (uintptr_t) *s++;
	if (*s == '\0') break;
	hash ^= (uintptr_t) *s++ << 8;
	if (*s == '\0') break;
	hash ^= (uintptr_t) *s++ << 16;
	if (*s == '\0') break;
	hash ^= (uintptr_t) *s++ << 24;
	}
    return hash;
    };

/// 判等字符串相等
int NXStrIsEqual (const void *info, const void *data1, const void *data2) {
    // 1.指针相等
    if (data1 == data2) return YES;
    // 2.1个没值，另一个有无值
    if (! data1) return ! strlen ((char *) data2);
    if (! data2) return ! strlen ((char *) data1);
    // 3.判等第0个是否 ==
    if (((char *) data1)[0] != ((char *) data2)[0]) return NO;
    // 4.全部比较
    return (strcmp ((char *) data1, (char *) data2)) ? NO : YES;
    };
    
void NXReallyFree (const void *info, void *data) {
    free (data);
    };

/* All the following functions are really private, made non-static only for the benefit of shlibs */
static uintptr_t hashPtrStructKey (const void *info, const void *data) {
    return NXPtrHash(info, *((void **) data));
    };

static int isEqualPtrStructKey (const void *info, const void *data1, const void *data2) {
    return NXPtrIsEqual (info, *((void **) data1), *((void **) data2));
    };

static uintptr_t hashStrStructKey (const void *info, const void *data) {
    return NXStrHash(info, *((char **) data));
    };

static int isEqualStrStructKey (const void *info, const void *data1, const void *data2) {
    return NXStrIsEqual (info, *((char **) data1), *((char **) data2));
    };

const NXHashTablePrototype NXPtrPrototype = {
    NXPtrHash, NXPtrIsEqual, NXNoEffectFree, 0
    };

const NXHashTablePrototype NXStrPrototype = {
    NXStrHash, NXStrIsEqual, NXNoEffectFree, 0
    };

const NXHashTablePrototype NXPtrStructKeyPrototype = {
    hashPtrStructKey, isEqualPtrStructKey, NXReallyFree, 0
    };

const NXHashTablePrototype NXStrStructKeyPrototype = {
    hashStrStructKey, isEqualStrStructKey, NXReallyFree, 0
    };

/*************************************************************************
 *
 *	Unique strings
 *	
 *************************************************************************/

#if !__OBJC2__  &&  !TARGET_OS_WIN32

/* the implementation could be made faster at the expense of memory if the size of the strings were kept around */
static NXHashTable *uniqueStrings = NULL;

/* this is based on most apps using a few K of strings, and an average string size of 15 using sqrt(2*dataAlloced*perChunkOverhead) */
#define CHUNK_SIZE	360

static int accessUniqueString = 0;

static char		*z = NULL;
static size_t	zSize = 0;
mutex_t		NXUniqueStringLock;

static const char *CopyIntoReadOnly (const char *str) {
    size_t	len = strlen (str) + 1;
    char	*result;
    
    if (len > CHUNK_SIZE/2) {	/* dont let big strings waste space */
	result = (char *)malloc (len);
	bcopy (str, result, len);
	return result;
    }

    mutex_locker_t lock(NXUniqueStringLock);
    if (zSize < len) {
	zSize = CHUNK_SIZE *((len + CHUNK_SIZE - 1) / CHUNK_SIZE);
	/* not enough room, we try to allocate.  If no room left, too bad */
	z = (char *)malloc (zSize);
	};
    
    result = z;
    bcopy (str, result, len);
    z += len;
    zSize -= len;
    return result;
    };
    
NXAtom NXUniqueString (const char *buffer) {
    const char	*previous;
    
    if (! buffer) return buffer;
    accessUniqueString++;
    if (! uniqueStrings)
    	uniqueStrings = NXCreateHashTable (NXStrPrototype, 0, NULL);
    previous = (const char *) NXHashGet (uniqueStrings, buffer);
    if (previous) return previous;
    previous = CopyIntoReadOnly (buffer);
    if (NXHashInsert (uniqueStrings, previous)) {
	_objc_inform ("*** NXUniqueString: invariant broken\n");
	return NULL;
	};
    return previous;
    };

NXAtom NXUniqueStringNoCopy (const char *string) {
    accessUniqueString++;
    if (! uniqueStrings)
    	uniqueStrings = NXCreateHashTable (NXStrPrototype, 0, NULL);
    return (const char *) NXHashInsertIfAbsent (uniqueStrings, string);
    };

#define BUF_SIZE	256

NXAtom NXUniqueStringWithLength (const char *buffer, int length) {
    NXAtom	atom;
    char	*nullTermStr;
    char	stackBuf[BUF_SIZE];

    if (length+1 > BUF_SIZE)
	nullTermStr = (char *)malloc (length+1);
    else
	nullTermStr = stackBuf;
    bcopy (buffer, nullTermStr, length);
    nullTermStr[length] = '\0';
    atom = NXUniqueString (nullTermStr);
    if (length+1 > BUF_SIZE)
	free (nullTermStr);
    return atom;
    };

char *NXCopyStringBufferFromZone (const char *str, void *zone) {
#if !SUPPORT_ZONES
    return strdup(str);
#else
    return strcpy ((char *) malloc_zone_malloc((malloc_zone_t *)zone, strlen (str) + 1), str);
#endif
    };
    
char *NXCopyStringBuffer (const char *str) {
    return strdup(str);
    };

#endif
