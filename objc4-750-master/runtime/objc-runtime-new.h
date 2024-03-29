 /*
 * Copyright (c) 2005-2007 Apple Inc.  All Rights Reserved.
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

#ifndef _OBJC_RUNTIME_NEW_H
#define _OBJC_RUNTIME_NEW_H

#if __LP64__
typedef uint32_t mask_t;  // x86_64 & arm64 asm are less efficient with 16-bits
#else
typedef uint16_t mask_t;
#endif
typedef uintptr_t cache_key_t;

struct swift_class_t;


struct bucket_t {
private:
    // IMP-first is better for arm64e ptrauth and no worse for arm64.
    // SEL-first is better for armv7* and i386 and x86_64.
#if __arm64__
    MethodCacheIMP _imp;
    cache_key_t _key;
#else
    // 方法的标示
    cache_key_t _key;
    // imp
    MethodCacheIMP _imp;
#endif

public:
    // set和get方法
    inline cache_key_t key() const { return _key; }
    inline IMP imp() const { return (IMP)_imp; }
    inline void setKey(cache_key_t newKey) { _key = newKey; }
    inline void setImp(IMP newImp) { _imp = newImp; }

    void set(cache_key_t newKey, IMP newImp);
};


struct cache_t {
    // 数据
    struct bucket_t *_buckets;
    // 散列表长度 - 1
    mask_t _mask;
    // 已经存的count
    mask_t _occupied;

public:
    /// get
    struct bucket_t *buckets();
    /// 散列表长度 - 1
    mask_t mask();
    /// 存的count
    mask_t occupied();
    /// 存的count + 1
    void incrementOccupied();
    /// 给属性赋值
    void setBucketsAndMask(struct bucket_t *newBuckets, mask_t newMask);
    /// _buckets是否是空的
    void initializeToEmpty();

    /// 容量 mask + 1
    mask_t capacity();
    /// 空的
    bool isConstantEmptyCache();
    /// 不是空的
    bool canBeFreed();

    static size_t bytesForCapacity(uint32_t cap);
    static struct bucket_t * endMarker(struct bucket_t *b, uint32_t cap);

    /// 扩容
    void expand();
    void reallocate(mask_t oldCapacity, mask_t newCapacity);
    // 获取缓存方法的bucket_t
    struct bucket_t * find(cache_key_t key, id receiver);

    static void bad_cache(id receiver, SEL sel, Class isa) __attribute__((noreturn));
};


// classref_t is unremapped class_t*
typedef struct classref * classref_t;

/***********************************************************************
* entsize_list_tt<Element, List, FlagMask>
* Generic implementation of an array of non-fragile structs.
*
* Element is the struct type (e.g. method_t)
* List is the specialization of entsize_list_tt (e.g. method_list_t)
* FlagMask is used to stash extra bits in the entsize field
*   (e.g. method list fixup markers)
**********************************************************************/
/// 1维数组
template <typename Element, typename List, uint32_t FlagMask>
struct entsize_list_tt {
    /// 通过位运算保存很多属性
    uint32_t entsizeAndFlags;
    uint32_t count;
    Element first;

    /// 元素所占的size
    uint32_t entsize() const {
        return entsizeAndFlags & ~FlagMask;
    }
    uint32_t flags() const {
        return entsizeAndFlags & FlagMask;
    }

    /// 获取第i位的元素
    Element& getOrEnd(uint32_t i) const { 
        assert(i <= count);
        return *(Element *)((uint8_t *)&first + i*entsize()); 
    }
    Element& get(uint32_t i) const { 
        assert(i < count);
        return getOrEnd(i);
    }

    size_t byteSize() const {
        return byteSize(entsize(), count);
    }
    
    static size_t byteSize(uint32_t entsize, uint32_t count) {
        return sizeof(entsize_list_tt) + (count-1)*entsize;
    }

    /// copy
    List *duplicate() const {
        auto *dup = (List *)calloc(this->byteSize(), 1);
        dup->entsizeAndFlags = this->entsizeAndFlags;
        dup->count = this->count;
        std::copy(begin(), end(), dup->begin());
        return dup;
    }

    /// 迭代器
    struct iterator;
    const iterator begin() const { 
        return iterator(*static_cast<const List*>(this), 0); 
    }
    iterator begin() { 
        return iterator(*static_cast<const List*>(this), 0); 
    }
    const iterator end() const { 
        return iterator(*static_cast<const List*>(this), count); 
    }
    iterator end() { 
        return iterator(*static_cast<const List*>(this), count); 
    }

    struct iterator {
        uint32_t entsize;
        uint32_t index;  // keeping track of this saves a divide in operator-
        // index位的元素
        Element* element;

        typedef std::random_access_iterator_tag iterator_category;
        typedef Element value_type;
        typedef ptrdiff_t difference_type;
        typedef Element* pointer;
        typedef Element& reference;

        iterator() { }

        /// iterator初始化方法
        iterator(const List& list, uint32_t start = 0)
            : entsize(list.entsize())
            , index(start)
            , element(&list.getOrEnd(start))
        { }

        /// 后delta位的迭代器
        const iterator& operator += (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element + delta*entsize);
            index += (int32_t)delta;
            return *this;
        }
        /// 前delta位的迭代器
        const iterator& operator -= (ptrdiff_t delta) {
            element = (Element*)((uint8_t *)element - delta*entsize);
            index -= (int32_t)delta;
            return *this;
        }
        const iterator operator + (ptrdiff_t delta) const {
            return iterator(*this) += delta;
        }
        const iterator operator - (ptrdiff_t delta) const {
            return iterator(*this) -= delta;
        }

        iterator& operator ++ () { *this += 1; return *this; }
        iterator& operator -- () { *this -= 1; return *this; }
        iterator operator ++ (int) {
            iterator result(*this); *this += 1; return result;
        }
        iterator operator -- (int) {
            iterator result(*this); *this -= 1; return result;
        }

        ptrdiff_t operator - (const iterator& rhs) const {
            return (ptrdiff_t)this->index - (ptrdiff_t)rhs.index;
        }

        /// 取引用
        Element& operator * () const { return *element; }
        /// 取指针
        Element* operator -> () const { return element; }

        operator Element& () const { return *element; }

        /// 判等
        bool operator == (const iterator& rhs) const {
            return this->element == rhs.element;
        }
        bool operator != (const iterator& rhs) const {
            return this->element != rhs.element;
        }

        bool operator < (const iterator& rhs) const {
            return this->element < rhs.element;
        }
        bool operator > (const iterator& rhs) const {
            return this->element > rhs.element;
        }
    };
};


struct method_t {
    SEL name;
    // 类型
    const char *types;
    // 指向函数实现的指针
    MethodListIMP imp;

    // 排序
    struct SortBySELAddress :
        public std::binary_function<const method_t&,
                                    const method_t&, bool>
    {
        bool operator() (const method_t& lhs,
                         const method_t& rhs)
        { return lhs.name < rhs.name; }
    };
};

struct ivar_t {
#if __x86_64__
    // *offset was originally 64-bit on some x86_64 platforms.
    // We read and write only 32 bits of it.
    // Some metadata provides all 64 bits. This is harmless for unsigned 
    // little-endian values.
    // Some code uses all 64 bits. class_addIvar() over-allocates the 
    // offset for their benefit.
#endif
    /// 偏移量, 通过它可以获取value
    int32_t *offset;
    const char *name;
    const char *type;
    // alignment is sometimes -1; use alignment() instead
    uint32_t alignment_raw;
    uint32_t size;

    // 内存对齐
    uint32_t alignment() const {
        if (alignment_raw == ~(uint32_t)0) return 1U << WORD_SHIFT;
        return 1 << alignment_raw;
    }
};

struct property_t {
    const char *name;
    // 类型
    const char *attributes;
};

// Two bits of entsize are used for fixup markers.
struct method_list_t : entsize_list_tt<method_t, method_list_t, 0x3> {
    bool isFixedUp() const;
    void setFixedUp();

    /// 求method的索引
    uint32_t indexOfMethod(const method_t *meth) const {
        uint32_t i = 
            (uint32_t)(((uintptr_t)meth - (uintptr_t)this) / entsize());
        assert(i < count);
        return i;
    }
};

struct ivar_list_t : entsize_list_tt<ivar_t, ivar_list_t, 0> {
    /// 是否包含这个成员属性
    bool containsIvar(Ivar ivar) const {
        return (ivar >= (Ivar)&*begin()  &&  ivar < (Ivar)&*end());
    }
};

struct property_list_t : entsize_list_tt<property_t, property_list_t, 0> {
};


typedef uintptr_t protocol_ref_t;  // protocol_t *, but unremapped

// Values for protocol_t->flags
#define PROTOCOL_FIXED_UP_2 (1<<31)  // must never be set by compiler
#define PROTOCOL_FIXED_UP_1 (1<<30)  // must never be set by compiler
// Bits 0..15 are reserved for Swift's use.

#define PROTOCOL_FIXED_UP_MASK (PROTOCOL_FIXED_UP_1 | PROTOCOL_FIXED_UP_2)

struct protocol_t : objc_object {
    // 协议名
    const char *mangledName;
    // 遵守的protocol
    struct protocol_list_t *protocols;
    // 对象方法
    method_list_t *instanceMethods;
    // 类方法
    method_list_t *classMethods;
    // 可选方法
    method_list_t *optionalInstanceMethods;
    method_list_t *optionalClassMethods;
    property_list_t *instanceProperties;
    uint32_t size;   // sizeof(protocol_t)
    uint32_t flags;
    // Fields below this point are not always present on disk.
    const char **_extendedMethodTypes;
    
    const char *_demangledName;
    property_list_t *_classProperties;

    const char *demangledName();

    const char *nameForLogging() {
        return demangledName();
    }

    bool isFixedUp() const;
    void setFixedUp();

#   define HAS_FIELD(f) (size >= offsetof(protocol_t, f) + sizeof(f))

    bool hasExtendedMethodTypesField() const {
        return HAS_FIELD(_extendedMethodTypes);
    }
    bool hasDemangledNameField() const {
        return HAS_FIELD(_demangledName);
    }
    bool hasClassPropertiesField() const {
        return HAS_FIELD(_classProperties);
    }

#   undef HAS_FIELD

    const char **extendedMethodTypes() const {
        return hasExtendedMethodTypesField() ? _extendedMethodTypes : nil;
    }

    property_list_t *classProperties() const {
        return hasClassPropertiesField() ? _classProperties : nil;
    }
};

struct protocol_list_t {
    // count is 64-bit by accident. 
    uintptr_t count;
    protocol_ref_t list[0]; // variable-size

    size_t byteSize() const {
        return sizeof(*this) + count*sizeof(list[0]);
    }

    protocol_list_t *duplicate() const {
        return (protocol_list_t *)memdup(this, this->byteSize());
    }

    /// 相当于迭代器, const_: 不变的
    typedef protocol_ref_t* iterator;
    typedef const protocol_ref_t* const_iterator;

    const_iterator begin() const {
        return list;
    }
    iterator begin() {
        return list;
    }
    const_iterator end() const {
        return list + count;
    }
    iterator end() {
        return list + count;
    }
};

struct locstamped_category_t {
    category_t *cat;
    // 根据它可以获得是否有class属性..
    struct header_info *hi;
};

struct locstamped_category_list_t {
    uint32_t count;
#if __LP64__
    uint32_t reserved;
#endif
    locstamped_category_t list[0];
};


// class_data_bits_t is the class_t->data field (class_rw_t pointer plus flags)
// The extra bits are optimized for the retain/release and alloc/dealloc paths.

// Values for class_ro_t->flags
// These are emitted by the compiler and are part of the ABI.
// Note: See CGObjCNonFragileABIMac::BuildClassRoTInitializer in clang
// class is a metaclass
#define RO_META               (1<<0)
// class is a root class
#define RO_ROOT               (1<<1)
// class has .cxx_construct/destruct implementations
#define RO_HAS_CXX_STRUCTORS  (1<<2)
// class has +load implementation
// #define RO_HAS_LOAD_METHOD    (1<<3)
// class has visibility=hidden set
#define RO_HIDDEN             (1<<4)
// class has attribute(objc_exception): OBJC_EHTYPE_$_ThisClass is non-weak
#define RO_EXCEPTION          (1<<5)
// this bit is available for reassignment
// #define RO_REUSE_ME           (1<<6) 
// class compiled with ARC
#define RO_IS_ARC             (1<<7)
// class has .cxx_destruct but no .cxx_construct (with RO_HAS_CXX_STRUCTORS)
#define RO_HAS_CXX_DTOR_ONLY  (1<<8)
// class is not ARC but has ARC-style weak ivar layout 
#define RO_HAS_WEAK_WITHOUT_ARC (1<<9)

// class is in an unloadable bundle - must never be set by compiler
#define RO_FROM_BUNDLE        (1<<29)
// class is unrealized future class - must never be set by compiler
#define RO_FUTURE             (1<<30)
// class is realized - must never be set by compiler
#define RO_REALIZED           (1<<31)

// Values for class_rw_t->flags
// These are not emitted by the compiler and are never used in class_ro_t. 
// Their presence should be considered in future ABI versions.
// class_t->data is class_rw_t, not class_ro_t
#define RW_REALIZED           (1<<31)
// class is unresolved future class
#define RW_FUTURE             (1<<30)
// class is initialized
#define RW_INITIALIZED        (1<<29)
// class is initializing
#define RW_INITIALIZING       (1<<28)
// class_rw_t->ro is heap copy of class_ro_t
#define RW_COPIED_RO          (1<<27)
// class allocated but not yet registered
#define RW_CONSTRUCTING       (1<<26)
// class allocated and registered
#define RW_CONSTRUCTED        (1<<25)
// available for use; was RW_FINALIZE_ON_MAIN_THREAD
// #define RW_24 (1<<24)
// class +load has been called
#define RW_LOADED             (1<<23)
#if !SUPPORT_NONPOINTER_ISA
// class instances may have associative references
#define RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS (1<<22)
#endif
// class has instance-specific GC layout
#define RW_HAS_INSTANCE_SPECIFIC_LAYOUT (1 << 21)
// available for use
// #define RW_20       (1<<20)
// class has started realizing but not yet completed it
#define RW_REALIZING          (1<<19)

// NOTE: MORE RW_ FLAGS DEFINED BELOW


// Values for class_rw_t->flags or class_t->bits
// These flags are optimized for retain/release and alloc/dealloc
// 64-bit stores more of them in class_t->bits to reduce pointer indirection.

#if !__LP64__

// class or superclass has .cxx_construct implementation
#define RW_HAS_CXX_CTOR       (1<<18)
// class or superclass has .cxx_destruct implementation
#define RW_HAS_CXX_DTOR       (1<<17)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define RW_HAS_DEFAULT_AWZ    (1<<16)
// class's instances requires raw isa
#if SUPPORT_NONPOINTER_ISA
#define RW_REQUIRES_RAW_ISA   (1<<15)
#endif
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define RW_HAS_DEFAULT_RR     (1<<14)

// class is a Swift class from the pre-stable Swift ABI
#define FAST_IS_SWIFT_LEGACY  (1UL<<0)
// class is a Swift class from the stable Swift ABI
#define FAST_IS_SWIFT_STABLE  (1UL<<1)
// data pointer 数据段的指针
#define FAST_DATA_MASK        0xfffffffcUL

#elif 1
// Leaks-compatible version that steals low bits only.

// class or superclass has .cxx_construct implementation 构造函数
#define RW_HAS_CXX_CTOR       (1<<18)
// class or superclass has .cxx_destruct implementation 析构函数
#define RW_HAS_CXX_DTOR       (1<<17)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass. 有默认的allocWithZone
#define RW_HAS_DEFAULT_AWZ    (1<<16)
// class's instances requires raw isa 类的实例需要原始isa
#define RW_REQUIRES_RAW_ISA   (1<<15)

// class is a Swift class from the pre-stable Swift ABI
#define FAST_IS_SWIFT_LEGACY    (1UL<<0)
// class is a Swift class from the stable Swift ABI
#define FAST_IS_SWIFT_STABLE    (1UL<<1)
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<2)
// data pointer 查找第0位，表示是否swift
/// 用于获取class_rw_t
#define FAST_DATA_MASK          0x00007ffffffffff8UL

#else
// Leaks-incompatible version that steals lots of bits.

// class is a Swift class from the pre-stable Swift ABI
#define FAST_IS_SWIFT_LEGACY    (1UL<<0)
// class is a Swift class from the stable Swift ABI
#define FAST_IS_SWIFT_STABLE    (1UL<<1)
// summary bit for fast alloc path: !hasCxxCtor and 
//   !instancesRequireRawIsa and instanceSize fits into shiftedSize
#define FAST_ALLOC              (1UL<<2)
// data pointer
#define FAST_DATA_MASK          0x00007ffffffffff8UL
// class or superclass has .cxx_construct implementation
#define FAST_HAS_CXX_CTOR       (1UL<<47)
// class or superclass has default alloc/allocWithZone: implementation
// Note this is is stored in the metaclass.
#define FAST_HAS_DEFAULT_AWZ    (1UL<<48)
// class or superclass has default retain/release/autorelease/retainCount/
//   _tryRetain/_isDeallocating/retainWeakReference/allowsWeakReference
#define FAST_HAS_DEFAULT_RR     (1UL<<49)
// class's instances requires raw isa
//   This bit is aligned with isa_t->hasCxxDtor to save an instruction. 类或父类需要初始化isa
#define FAST_REQUIRES_RAW_ISA   (1UL<<50)
// class or superclass has .cxx_destruct implementation
#define FAST_HAS_CXX_DTOR       (1UL<<51)
// instance size in units of 16 bytes
//   or 0 if the instance size is too big in this field
//   This field must be LAST
#define FAST_SHIFTED_SIZE_SHIFT 52

// FAST_ALLOC means
//   FAST_HAS_CXX_CTOR is set
//   FAST_REQUIRES_RAW_ISA is not set
//   FAST_SHIFTED_SIZE is not zero
// FAST_ALLOC does NOT check FAST_HAS_DEFAULT_AWZ because that 
// bit is stored on the metaclass.
#define FAST_ALLOC_MASK  (FAST_HAS_CXX_CTOR | FAST_REQUIRES_RAW_ISA)
#define FAST_ALLOC_VALUE (0)

#endif

// The Swift ABI requires that these bits be defined like this on all platforms.
static_assert(FAST_IS_SWIFT_LEGACY == 1, "resistance is futile");
static_assert(FAST_IS_SWIFT_STABLE == 2, "resistance is futile");


struct class_ro_t {
    // 用位运算保存的很多信息, 比如: flags & RO_META是否为元类
    uint32_t flags;
    // 对象起始偏移量，没有对齐
    uint32_t instanceStart;
    // 这个变量总共存储了对象实例化时，所有变量所占的内存大小
    // 这个大小是在编译器就已经决定的，不能在运行时进行动态改变
    uint32_t instanceSize;
#ifdef __LP64__
    uint32_t reserved;
#endif

    /// 成员变量布局
    const uint8_t * ivarLayout;
    
    const char * name; // 类名
    // 是一维数组，不可变👍
    method_list_t * baseMethodList; // 方法列表
    protocol_list_t * baseProtocols;
    /// 成员属性列表, const表示ivars指向的值不能变, 指向的地址可以变
    const ivar_list_t * ivars;

    const uint8_t * weakIvarLayout;
    /// 属性列表
    property_list_t *baseProperties;

    /// 方法列表
    method_list_t *baseMethods() const {
        return baseMethodList;
    }
};


/***********************************************************************
* list_array_tt<Element, List>
* Generic implementation for metadata that can be augmented by categories.
*
* Element is the underlying metadata type (e.g. method_t)
* List is the metadata's list type (e.g. method_list_t)
*
* A list_array_tt has one of three values:
* - empty
* - a pointer to a single list
* - an array of pointers to lists
*
* countLists/beginLists/endLists iterate the metadata lists
* count/begin/end iterate the underlying metadata elements
**********************************************************************/
/// 方法列表(2维数组)
template <typename Element, typename List>
class list_array_tt {
    /// 2维List
    struct array_t {
        uint32_t count;
        /// 等价于 List **, 数组指针
        List* lists[0];

        /// 有count个list的array_t内存
        static size_t byteSize(uint32_t count) {
            return sizeof(array_t) + count*sizeof(lists[0]);
        }
        /// array_t所占内存
        size_t byteSize() {
            return byteSize(count);
        }
    };

 protected:
    /// 迭代器, List是泛型
    /// 可以看出为2维数组
    class iterator {
        /// 每一层的list
        List **lists;
        /// 最后一层的后一层
        List **listsEnd;
        /// list的迭代器
        typename List::iterator m, mEnd;

     public:
        iterator(List **begin, List **end) 
            : lists(begin), listsEnd(end)
        {
            if (begin != end) {
                m = (*begin)->begin();
                mEnd = (*begin)->end();
            }
        }

        /// 获取值
        const Element& operator * () const {
            return *m;
        }
        Element& operator * () {
            return *m;
        }

        bool operator != (const iterator& rhs) const {
            if (lists != rhs.lists) return true;
            if (lists == listsEnd) return false;  // m is undefined
            if (m != rhs.m) return true;
            return false;
        }

        /// 可以看出为2维数组
        const iterator& operator ++ () {
            assert(m != mEnd);
            // 1.list的迭代器后移
            m++;
            // 2. == end
            if (m == mEnd) {
                assert(lists != listsEnd);
                // 3. 下一个list
                lists++;
                // 4.list != 最后的
                if (lists != listsEnd) {
                    // 5.更新m, 完了一个数组, 再下一个数组
                    m = (*lists)->begin();
                    mEnd = (*lists)->end();
                }
            }
            return *this;
        }
    };

 private:
    /// union: 一次只有一种值
    union {
        /// 类型: array_t
        List* list;
        /// (array_t *)(arrayAndFlag & ~1);
        uintptr_t arrayAndFlag;
    };

    bool hasArray() const {
        return arrayAndFlag & 1;
    }

    /// array_t有2维的list
    array_t *array() {
        return (array_t *)(arrayAndFlag & ~1);
    }

    void setArray(array_t *array) {
        arrayAndFlag = (uintptr_t)array | 1;
    }

 public:

    /// 每个list的count的总和
    uint32_t count() {
        uint32_t result = 0;
        for (auto lists = beginLists(), end = endLists(); 
             lists != end; ++lists) {
            result += (*lists)->count;
        }
        return result;
    }

    iterator begin() {
        return iterator(beginLists(), endLists());
    }

    iterator end() {
        List **e = endLists();
        return iterator(e, e);
    }

    /// 多少个list
    uint32_t countLists() {
        if (hasArray()) {
            return array()->count;
        } else if (list) {
            return 1;
        } else {
            return 0;
        }
    }

    /// 2维, 开始的list
    List** beginLists() {
        if (hasArray()) {
            return array()->lists;
        } else {
            // List *list, 再取地址就2个*
            return &list;
        }
    }

    List** endLists() {
        if (hasArray()) {
            return array()->lists + array()->count;
        } else if (list) {
            return &list + 1;
        } else {
            return &list;
        }
    }

    /// 将addedLists方法添加到进去, 并且放在原来方法的前面
    void attachLists(List* const * addedLists, uint32_t addedCount) {
        if (addedCount == 0) return;

        // 1.是array
        if (hasArray()) {
            // 1.1.更新count
            uint32_t oldCount = array()->count;
            uint32_t newCount = oldCount + addedCount;
            // 1.2.重新分配newCount的内存的array
            setArray((array_t *)realloc(array(), array_t::byteSize(newCount)));
            // 1.3.更新array的count
            array()->count = newCount;
            // 1.4.这是old的method, 从addedCount开始, 可以看出它是放在new的后面
            memmove(array()->lists + addedCount, array()->lists,
                    oldCount * sizeof(array()->lists[0]));
            // 1.5.这是新加的, 看出它是放在前面
            memcpy(array()->lists, addedLists,
                   addedCount * sizeof(array()->lists[0]));
        }
        // 2.之前没list, 把list指向addedLists的地址
        else if (!list  &&  addedCount == 1) {
            // 0 lists -> 1 list
            list = addedLists[0];
        } 
        else {
            // 3.之前有list
            // list -> many lists
            List* oldList = list;
            // 3.1.之前有list为1, 否则为0
            uint32_t oldCount = oldList ? 1 : 0;
            // 3.2.加上新的count
            uint32_t newCount = oldCount + addedCount;
            // 3.3.重新分配newCount的array_t内存
            setArray((array_t *)malloc(array_t::byteSize(newCount)));
            // 3.4.更新count
            array()->count = newCount;
            // 3.5.有old, old放在后面
            if (oldList) array()->lists[addedCount] = oldList;
            // 3.6.把new的copy到开头
            // 参数说明: 开始地址, 数据, 所占内存
            memcpy(array()->lists, addedLists,
                   addedCount * sizeof(array()->lists[0]));
        }
    }

    /// 释放
    void tryFree() {
        if (hasArray()) {
            for (uint32_t i = 0; i < array()->count; i++) {
                try_free(array()->lists[i]);
            }
            try_free(array());
        }
        else if (list) {
            try_free(list);
        }
    }

    /// copy一份
    template<typename Result>
    Result duplicate() {
        Result result;

        if (hasArray()) {
            array_t *a = array();
            result.setArray((array_t *)memdup(a, a->byteSize()));
            for (uint32_t i = 0; i < a->count; i++) {
                result.array()->lists[i] = a->lists[i]->duplicate();
            }
        } else if (list) {
            result.list = list->duplicate();
        } else {
            result.list = nil;
        }

        return result;
    }
};

/// 2维数组
class method_array_t : public list_array_tt<method_t, method_list_t>
{
    typedef list_array_tt<method_t, method_list_t> Super;

 public:
    method_list_t **beginCategoryMethodLists() {
        return beginLists();
    }
    
    method_list_t **endCategoryMethodLists(Class cls);

    method_array_t duplicate() {
        return Super::duplicate<method_array_t>();
    }
};


class property_array_t : public list_array_tt<property_t, property_list_t>
{
    typedef list_array_tt<property_t, property_list_t> Super;

 public:
    property_array_t duplicate() {
        return Super::duplicate<property_array_t>();
    }
};


class protocol_array_t : public list_array_tt<protocol_ref_t, protocol_list_t>
{
    typedef list_array_tt<protocol_ref_t, protocol_list_t> Super;

 public:
    protocol_array_t duplicate() {
        return Super::duplicate<protocol_array_t>();
    }
};

/// 保存了method，property，protocol
struct class_rw_t {
    // Be warned that Symbolication knows the layout of this structure.
    uint32_t flags;
    // 版本信息，默认为0，可以通过runtime函数 class_setVersion设置
    uint32_t version;

    const class_ro_t *ro;

    // 二维数组，可读可写，包含了类的初始内容、分类内容👍
    method_array_t methods;
    property_array_t properties;
    protocol_array_t protocols;

    Class firstSubclass;
    Class nextSiblingClass;

    char *demangledName;

#if SUPPORT_INDEXED_ISA
    uint32_t index;
#endif

    // 一些关于flag的方法
    
    void setFlags(uint32_t set) 
    {
        OSAtomicOr32Barrier(set, &flags);
    }

    void clearFlags(uint32_t clear) 
    {
        OSAtomicXor32Barrier(clear, &flags);
    }

    // set and clear must not overlap
    void changeFlags(uint32_t set, uint32_t clear) 
    {
        assert((set & clear) == 0);

        uint32_t oldf, newf;
        do {
            oldf = flags;
            newf = (oldf | set) & ~clear;
        } while (!OSAtomicCompareAndSwap32Barrier(oldf, newf, (volatile int32_t *)&flags));
    }
};


struct class_data_bits_t {

    // Values are the FAST_ flags above.
    uintptr_t bits;
private:
    bool getBit(uintptr_t bit)
    {
        return bits & bit;
    }

#if FAST_ALLOC
    static uintptr_t updateFastAlloc(uintptr_t oldBits, uintptr_t change)
    {
        if (change & FAST_ALLOC_MASK) {
            if (((oldBits & FAST_ALLOC_MASK) == FAST_ALLOC_VALUE)  &&  
                ((oldBits >> FAST_SHIFTED_SIZE_SHIFT) != 0)) 
            {
                oldBits |= FAST_ALLOC;
            } else {
                oldBits &= ~FAST_ALLOC;
            }
        }
        return oldBits;
    }
#else
    static uintptr_t updateFastAlloc(uintptr_t oldBits, uintptr_t change) {
        return oldBits;
    }
#endif

    void setBits(uintptr_t set) 
    {
        uintptr_t oldBits;
        uintptr_t newBits;
        do {
            oldBits = LoadExclusive(&bits);
            newBits = updateFastAlloc(oldBits | set, set);
        } while (!StoreReleaseExclusive(&bits, oldBits, newBits));
    }

    void clearBits(uintptr_t clear) 
    {
        uintptr_t oldBits;
        uintptr_t newBits;
        do {
            oldBits = LoadExclusive(&bits);
            newBits = updateFastAlloc(oldBits & ~clear, clear);
        } while (!StoreReleaseExclusive(&bits, oldBits, newBits));
    }

public:

    /// 获得rw
    class_rw_t* data() {
        return (class_rw_t *)(bits & FAST_DATA_MASK);
    }
    
    /// 更新rw
    void setData(class_rw_t *newData)
    {
        assert(!data()  ||  (newData->flags & (RW_REALIZING | RW_FUTURE)));
        // Set during realization or construction only. No locking needed.
        // Use a store-release fence because there may be concurrent
        // readers of data and data's contents.
        uintptr_t newBits = (bits & ~FAST_DATA_MASK) | (uintptr_t)newData;
        atomic_thread_fence(memory_order_release);
        bits = newBits;
    }

#if FAST_HAS_DEFAULT_RR
    /// 有默认的retain、release... 内存分配方法
    bool hasDefaultRR() {
        return getBit(FAST_HAS_DEFAULT_RR);
    }
    void setHasDefaultRR() {
        setBits(FAST_HAS_DEFAULT_RR);
    }
    void setHasCustomRR() {
        clearBits(FAST_HAS_DEFAULT_RR);
    }
#else
    bool hasDefaultRR() {
        return data()->flags & RW_HAS_DEFAULT_RR;
    }
    void setHasDefaultRR() {
        data()->setFlags(RW_HAS_DEFAULT_RR);
    }
    void setHasCustomRR() {
        data()->clearFlags(RW_HAS_DEFAULT_RR);
    }
#endif

#if FAST_HAS_DEFAULT_AWZ
    bool hasDefaultAWZ() {
        return getBit(FAST_HAS_DEFAULT_AWZ);
    }
    void setHasDefaultAWZ() {
        setBits(FAST_HAS_DEFAULT_AWZ);
    }
    void setHasCustomAWZ() {
        clearBits(FAST_HAS_DEFAULT_AWZ);
    }
#else
    // RW_HAS_DEFAULT_AWZ 这个是用来标示当前的class或者是superclass是否有默认的alloc/allocWithZone:
    bool hasDefaultAWZ() {
        return data()->flags & RW_HAS_DEFAULT_AWZ;
    }
    void setHasDefaultAWZ() {
        data()->setFlags(RW_HAS_DEFAULT_AWZ);
    }
    void setHasCustomAWZ() {
        data()->clearFlags(RW_HAS_DEFAULT_AWZ);
    }
#endif

#if FAST_HAS_CXX_CTOR
    bool hasCxxCtor() {
        return getBit(FAST_HAS_CXX_CTOR);
    }
    void setHasCxxCtor() {
        setBits(FAST_HAS_CXX_CTOR);
    }
#else
    /// 有构造函数, cxx_construct
    bool hasCxxCtor() {
        return data()->flags & RW_HAS_CXX_CTOR;
    }
    void setHasCxxCtor() {
        data()->setFlags(RW_HAS_CXX_CTOR);
    }
#endif

#if FAST_HAS_CXX_DTOR
    bool hasCxxDtor() {
        return getBit(FAST_HAS_CXX_DTOR);
    }
    void setHasCxxDtor() {
        setBits(FAST_HAS_CXX_DTOR);
    }
#else
    /// 有析构函数, cxx_destruct
    bool hasCxxDtor() {
        return data()->flags & RW_HAS_CXX_DTOR;
    }
    void setHasCxxDtor() {
        data()->setFlags(RW_HAS_CXX_DTOR);
    }
#endif

#if FAST_REQUIRES_RAW_ISA
    bool instancesRequireRawIsa() {
        return getBit(FAST_REQUIRES_RAW_ISA);
    }
    void setInstancesRequireRawIsa() {
        setBits(FAST_REQUIRES_RAW_ISA);
    }
#elif SUPPORT_NONPOINTER_ISA
    bool instancesRequireRawIsa() {
        return data()->flags & RW_REQUIRES_RAW_ISA;
    }
    void setInstancesRequireRawIsa() {
        data()->setFlags(RW_REQUIRES_RAW_ISA);
    }
#else
    bool instancesRequireRawIsa() {
        return true;
    }
    void setInstancesRequireRawIsa() {
        // nothing
    }
#endif

#if FAST_ALLOC
    size_t fastInstanceSize() 
    {
        assert(bits & FAST_ALLOC);
        return (bits >> FAST_SHIFTED_SIZE_SHIFT) * 16;
    }
    void setFastInstanceSize(size_t newSize) 
    {
        // Set during realization or construction only. No locking needed.
        assert(data()->flags & RW_REALIZING);

        // Round up to 16-byte boundary, then divide to get 16-byte units
        newSize = ((newSize + 15) & ~15) / 16;
        
        uintptr_t newBits = newSize << FAST_SHIFTED_SIZE_SHIFT;
        if ((newBits >> FAST_SHIFTED_SIZE_SHIFT) == newSize) {
            int shift = WORD_BITS - FAST_SHIFTED_SIZE_SHIFT;
            uintptr_t oldBits = (bits << shift) >> shift;
            if ((oldBits & FAST_ALLOC_MASK) == FAST_ALLOC_VALUE) {
                newBits |= FAST_ALLOC;
            }
            bits = oldBits | newBits;
        }
    }

    bool canAllocFast() {
        return bits & FAST_ALLOC;
    }
#else
    size_t fastInstanceSize() {
        abort();
    }
    void setFastInstanceSize(size_t) {
        // nothing
    }
    bool canAllocFast() {
        return false;
    }
#endif

    void setClassArrayIndex(unsigned Idx) {
#if SUPPORT_INDEXED_ISA
        // 0 is unused as then we can rely on zero-initialisation from calloc.
        assert(Idx > 0);
        data()->index = Idx;
#endif
    }

    unsigned classArrayIndex() {
#if SUPPORT_INDEXED_ISA
        return data()->index;
#else
        return 0;
#endif
    }

    bool isAnySwift() {
        return isSwiftStable() || isSwiftLegacy();
    }

    bool isSwiftStable() {
        return getBit(FAST_IS_SWIFT_STABLE);
    }
    void setIsSwiftStable() {
        setBits(FAST_IS_SWIFT_STABLE);
    }

    bool isSwiftLegacy() {
        return getBit(FAST_IS_SWIFT_LEGACY);
    }
    void setIsSwiftLegacy() {
        setBits(FAST_IS_SWIFT_LEGACY);
    }
};

/*
 继承自objc_object，也有isa，执行meta class
 */
struct objc_class : objc_object {
    // objc_object保存了isa_t isa;
    
    Class superclass;
    /// 方法缓存
    cache_t cache;             // formerly cache pointer and vtable
    // 方法，属性，protocol...都保存在这
    class_data_bits_t bits;    // class_rw_t * plus custom rr/alloc flags

    /// 参数保存在这里面、rw
    class_rw_t *data() { 
        return bits.data();
    }
    /// 更新rw
    void setData(class_rw_t *newData) {
        bits.setData(newData);
    }
    
    /// flag的一些方法

    void setInfo(uint32_t set) {
        assert(isFuture()  ||  isRealized());
        data()->setFlags(set);
    }

    void clearInfo(uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        data()->clearFlags(clear);
    }

    // set and clear must not overlap
    void changeInfo(uint32_t set, uint32_t clear) {
        assert(isFuture()  ||  isRealized());
        assert((set & clear) == 0);
        data()->changeFlags(set, clear);
    }

    /// 是否有自定义的内存管理方法 - retain、release...
    bool hasCustomRR() {
        return ! bits.hasDefaultRR();
    }
    void setHasDefaultRR() {
        assert(isInitializing());
        bits.setHasDefaultRR();
    }
    void setHasCustomRR(bool inherited = false);
    void printCustomRR(bool inherited);

    /// 是否有默认的alloc/allocWithZone:
    bool hasCustomAWZ() {
        return ! bits.hasDefaultAWZ();
    }
    void setHasDefaultAWZ() {
        assert(isInitializing());
        bits.setHasDefaultAWZ();
    }
    void setHasCustomAWZ(bool inherited = false);
    void printCustomAWZ(bool inherited);

    bool instancesRequireRawIsa() {
        return bits.instancesRequireRawIsa();
    }
    void setInstancesRequireRawIsa(bool inherited = false);
    void printInstancesRequireRawIsa(bool inherited);

    bool canAllocNonpointer() {
        assert(!isFuture());
        return !instancesRequireRawIsa();
    }
    bool canAllocFast() {
        assert(!isFuture());
        return bits.canAllocFast();
    }


    bool hasCxxCtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return bits.hasCxxCtor();
    }
    void setHasCxxCtor() { 
        bits.setHasCxxCtor();
    }

    bool hasCxxDtor() {
        // addSubclass() propagates this flag from the superclass.
        assert(isRealized());
        return bits.hasCxxDtor();
    }
    void setHasCxxDtor() { 
        bits.setHasCxxDtor();
    }


    bool isSwiftStable() {
        return bits.isSwiftStable();
    }

    bool isSwiftLegacy() {
        return bits.isSwiftLegacy();
    }

    bool isAnySwift() {
        return bits.isAnySwift();
    }


    // Return YES if the class's ivars are managed by ARC, 
    // or the class is MRC but has ARC-style weak ivars.
    bool hasAutomaticIvars() {
        return data()->ro->flags & (RO_IS_ARC | RO_HAS_WEAK_WITHOUT_ARC);
    }

    // Return YES if the class's ivars are managed by ARC.
    bool isARC() {
        return data()->ro->flags & RO_IS_ARC;
    }


#if SUPPORT_NONPOINTER_ISA
    // Tracked in non-pointer isas; not tracked otherwise
#else
    bool instancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        return data()->flags & RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS;
    }

    void setInstancesHaveAssociatedObjects() {
        // this may be an unrealized future class in the CF-bridged case
        assert(isFuture()  ||  isRealized());
        setInfo(RW_INSTANCES_HAVE_ASSOCIATED_OBJECTS);
    }
#endif

    bool shouldGrowCache() {
        return true;
    }

    void setShouldGrowCache(bool) {
        // fixme good or bad for memory use?
    }

    /// 有无实现initialize
    bool isInitializing() {
        return getMeta()->data()->flags & RW_INITIALIZING;
    }

    void setInitializing() {
        assert(!isMetaClass());
        ISA()->setInfo(RW_INITIALIZING);
    }

    bool isInitialized() {
        return getMeta()->data()->flags & RW_INITIALIZED;
    }

    void setInitialized();

    bool isLoadable() {
        assert(isRealized());
        return true;  // any class registered for +load is definitely loadable
    }

    IMP getLoadMethod();

    // 是否初始化 Locking: To prevent concurrent realization, hold runtimeLock.
    bool isRealized() {
        return data()->flags & RW_REALIZED;
    }

    // Returns true if this is an unrealized future class. 如果这是未实现的未来类，则返回true
    // Locking: To prevent concurrent realization, hold runtimeLock.
    bool isFuture() { 
        return data()->flags & RW_FUTURE;
    }

    /// 是否为元类
    bool isMetaClass() {
        assert(this);
        assert(isRealized());
        return data()->ro->flags & RO_META;
    }

    // NOT identical to this->ISA when this is a metaclass
    Class getMeta() {
        if (isMetaClass()) return (Class)this;
        else return this->ISA();
    }

    /// 是否为根class
    bool isRootClass() {
        return superclass == nil;
    }
    /// 根元类的isa 是 self
    bool isRootMetaclass() {
        return ISA() == (Class)this;
    }

    const char *mangledName() { 
        // fixme can't assert locks here
        assert(this);

        if (isRealized()  ||  isFuture()) {
            return data()->ro->name;
        } else {
            return ((const class_ro_t *)data())->name;
        }
    }
    
    const char *demangledName(bool realize = false);
    const char *nameForLogging();

    /// 所占内存相关的方法x
    
    // 没有对齐的属性的起始偏移量
    // May be unaligned depending on class's ivars.
    uint32_t unalignedInstanceStart() {
        assert(isRealized());
        return data()->ro->instanceStart;
    }

    /// 对齐的属性的起始偏移量
    // Class's instance start rounded up to a pointer-size boundary.
    // This is used for ARC layout bitmaps.
    uint32_t alignedInstanceStart() {
        return word_align(unalignedInstanceStart());
    }

    // May be unaligned depending on class's ivars.
    uint32_t unalignedInstanceSize() {
        assert(isRealized());
        return data()->ro->instanceSize;
    }

    // Class's ivar size rounded up to a pointer-size boundary.
    uint32_t alignedInstanceSize() {
        return word_align(unalignedInstanceSize());
    }

    /// 获取到instanceSize后，对获取到的size进行地址对其
    /// 需要注意的是，CF框架要求所有对象大小最少的16字节，如果不够则定义为16字节
    size_t instanceSize(size_t extraBytes) {
        size_t size = alignedInstanceSize() + extraBytes;
        // CF requires all objects be at least 16 bytes.
        if (size < 16) size = 16;
        return size;
    }

    void setInstanceSize(uint32_t newSize) {
        assert(isRealized());
        if (newSize != data()->ro->instanceSize) {
            assert(data()->flags & RW_COPIED_RO);
            // 给const赋值
            *const_cast<uint32_t *>(&data()->ro->instanceSize) = newSize;
        }
        bits.setFastInstanceSize(newSize);
    }

    void chooseClassArrayIndex();

    void setClassArrayIndex(unsigned Idx) {
        bits.setClassArrayIndex(Idx);
    }

    unsigned classArrayIndex() {
        return bits.classArrayIndex();
    }

};

// MARK: - swift_class_t
struct swift_class_t : objc_class {
    uint32_t flags;
    uint32_t instanceAddressOffset;
    uint32_t instanceSize;
    uint16_t instanceAlignMask;
    uint16_t reserved;

    uint32_t classSize;
    uint32_t classAddressOffset;
    void *description;
    // ...

    void *baseAddress() {
        return (void *)((uint8_t *)this - classAddressOffset);
    }
};

/// 分类
struct category_t {
    const char *name;
    /// 哪个class的
    classref_t cls;
    /// 对象方法
    struct method_list_t *instanceMethods;
    /// 类方法
    struct method_list_t *classMethods;
    /// 协议
    struct protocol_list_t *protocols;
    /// 对象属性
    struct property_list_t *instanceProperties;
    /// 类属性 Fields below this point are not always present on disk.
    struct property_list_t *_classProperties;

    /// 元类是类方法，其他的是对象方法
    method_list_t *methodsForMeta(bool isMeta) {
        if (isMeta) return classMethods;
        else return instanceMethods;
    }

    /// 不是元类是对象属性, 有分类class属性才返回class属性, 否则nil
    property_list_t *propertiesForMeta(bool isMeta, struct header_info *hi);
};

/// super结构体
struct objc_super2 {
    /// 为当前class的objc
    id receiver;
    /// 当前的类名
    Class current_class;
};

struct message_ref_t {
    IMP imp;
    SEL sel;
};

/// 获取protocol的方法
extern Method protocol_getMethod(protocol_t *p, SEL sel, bool isRequiredMethod, bool isInstanceMethod, bool recursive);

static inline void
foreach_realized_class_and_subclass_2(Class top, unsigned& count,
                                      std::function<bool (Class)> code) 
{
    // runtimeLock.assertLocked();
    assert(top);
    Class cls = top;
    while (1) {
        if (--count == 0) {
            _objc_fatal("Memory corruption in class list.");
        }
        if (!code(cls)) break;

        // 1.有firstSubclass, cls = firstSubclass
        if (cls->data()->firstSubclass) {
            cls = cls->data()->firstSubclass;
        } else {
            // 2.没兄弟, 找super
            while (!cls->data()->nextSiblingClass  &&  cls != top) {
                cls = cls->superclass;
                if (--count == 0) {
                    _objc_fatal("Memory corruption in class list.");
                }
            }
            if (cls == top) break;
            cls = cls->data()->nextSiblingClass;
        }
    }
}

extern Class firstRealizedClass();
extern unsigned int unreasonableClassCount();

// Enumerates a class and all of its realized subclasses. 遍历class和所有它实现的子类
static inline void
foreach_realized_class_and_subclass(Class top,
                                    std::function<void (Class)> code)
{
    unsigned int count = unreasonableClassCount();

    foreach_realized_class_and_subclass_2(top, count,
                                          [&code](Class cls) -> bool
    {
        code(cls);
        return true; 
    });
}

// Enumerates all realized classes and metaclasses. 遍历所有实现的类和元类
static inline void
foreach_realized_class_and_metaclass(std::function<void (Class)> code) 
{
    unsigned int count = unreasonableClassCount();
    
    for (Class top = firstRealizedClass(); 
         top != nil; 
         top = top->data()->nextSiblingClass) {
        foreach_realized_class_and_subclass_2(top, count,
                                              [&code](Class cls) -> bool
        {
            code(cls);
            return true; 
        });
    }

}

#endif
